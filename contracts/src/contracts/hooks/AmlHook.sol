// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookGovernance} from "./AmlHookGovernance.sol";
import {AmlHookLogic} from "./AmlHookLogic.sol";
import {AmlHookSettlement} from "./AmlHookSettlement.sol";
import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IFeeEscrow} from "../../interfaces/escrow/IFeeEscrow.sol";
import {IComplianceTreasury} from "../../interfaces/treasury/IComplianceTreasury.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";
import {LiquidityCache} from "../../libraries/LiquidityCache.sol";
import {SwapCache} from "../../libraries/SwapCache.sol";
import {SwapCurrencies} from "../../libraries/SwapCurrencies.sol";
import {OracleQuote} from "../../libraries/OracleQuote.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title AmlHook — Uniswap v4 AML hook entry-point
/// @notice Uniswap v4 callback shell that wires settlement, governance, and compliance logic.
///         Risk evaluation reads the published COA row (`AmlHookLogic` / `RiskPolicyLib`);
///         fee custody lives in `AmlHookSettlement`. The hook never calls the agent.
contract AmlHook is AmlHookSettlement, AmlHookLogic {
    using PoolIdLibrary for PoolKey;

    /// @dev Guards initialize() so it can only be called once.
    bool private _initialized;

    /// @notice Thrown when initialize() is called more than once.
    error AlreadyInitialized();

    /// @param poolManager_   Uniswap v4 PoolManager (passed to BaseHook).
    /// @param accessManager_ OpenZeppelin AccessManager that governs role assignments.
    constructor(IPoolManager poolManager_, address accessManager_)
        AmlHookSettlement(poolManager_)
        AmlHookGovernance(accessManager_)
    {}

    /// @notice One-time wiring of compliance dependencies. Must be called immediately after CREATE2 deploy.
    /// @param sanctionRegistry_   Layer 1 sanctions list (fail-closed screen).
    /// @param complianceOracle_   Layer 2 store of COA scores published by the oracle keeper.
    /// @param riskPolicy_         Layer 3 pure decision contract (preview / off-chain use).
    /// @param feeEscrow_          48-hour escrow for FEE_OVERRIDE differentials; `address(0)` disables.
    /// @param complianceTreasury_ Ledged compliance fund; `address(0)` skips principal credit.
    /// @param stalenessThreshold_ Seconds after which a score is considered stale (Floor B);
    ///        0 → DEFAULT_STALENESS (5 minutes). Off-chain tick is 3 minutes so a healthy
    ///        keeper stays inside this window without re-running the agent.
    /// @param activityWindow_     Rolling window for operation-count and USD accumulators; 0 → DEFAULT_ACTIVITY_WINDOW.
    function initialize(
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        IFeeEscrow feeEscrow_,
        IComplianceTreasury complianceTreasury_,
        uint256 stalenessThreshold_,
        uint64 activityWindow_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _initSettlement(feeEscrow_, complianceTreasury_);
        _initGovernance(sanctionRegistry_, complianceOracle_, riskPolicy_, stalenessThreshold_, activityWindow_);
    }

    /// @notice Governor grants or revokes a subject's right to reclaim a failed-deposit balance for `token`.
    /// @dev Single-use approval consumed on `claimFailedDeposit` (M-02 fix).
    /// @param wallet   Compliance subject (swap originator).
    /// @param token    ERC-20 token of the stranded balance.
    /// @param approved True to allow the claim; false to revoke.
    function approveFailedDepositRefund(address wallet, address token, bool approved) external restricted {
        _setFailedDepositRefundApproval(wallet, token, approved);
    }

    /// @notice Returns the Uniswap v4 hook permission bitmap for this hook.
    /// @dev Enables beforeAddLiquidity, beforeRemoveLiquidity, afterRemoveLiquidity,
    ///      afterRemoveLiquidityReturnDelta, beforeSwap, afterSwap, afterSwapReturnDelta.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /// @dev L1 + score ≥ 71 block a new deposit. A trusted router reports `msgSender()` as the LP.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        _guardAddLiquidity(sender);
        return this.beforeAddLiquidity.selector;
    }

    /// @dev L1 or score ≥ 71 → seize after the remove (LP receives 0). Pause does not run (H-1).
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        (address wallet, bool seize, uint8 score, bool viaRouter) = _evaluateRemoveLiquidity(sender);
        LiquidityCache.store(key.toId(), wallet, seize, score, viaRouter);
        return this.beforeRemoveLiquidity.selector;
    }

    /// @dev If the cache says seize, take the full delta: principal → treasury, fees → FeeEscrow.
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, BalanceDelta) {
        (address wallet, bool seize,,) = LiquidityCache.load(key.toId());
        LiquidityCache.clear(key.toId());
        if (!seize) return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
        return (this.afterRemoveLiquidity.selector, _seizeLpExit(wallet, key, params, delta, feesAccrued));
    }

    /// @dev Resolves the compliance subject, reads the published COA row, runs L1→L3, and
    ///      stores the result in transient storage so `_afterSwap` can settle without
    ///      re-reading the oracle. The hook never calls the agent.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _cacheStore(key, _beginSwapFromKey(sender, key, params));
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Loads the transient evaluation, clears the cache, records activity, and takes the
    ///      differential fee into escrow when the decision is FEE_OVERRIDE.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, int128) {
        return (this.afterSwap.selector, _completeSwap(key, params, delta));
    }

    /// @dev Cache-load, activity, then escrow. Isolated so `_afterSwap` does not keep
    ///      `SwapEvaluation` + Uniswap types in the same callback frame.
    function _completeSwap(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        private
        returns (int128 hookDelta)
    {
        SwapEvaluation memory ev = _takeEval(key);
        _finishSwap(ev, key, params, delta);
        hookDelta = _maybeEscrow(ev, key, params, delta);
    }

    function _takeEval(PoolKey calldata key) private returns (SwapEvaluation memory ev) {
        ev = _cacheLoad(key);
        SwapCache.clear(key.toId());
    }

    /// @dev Unwraps pool currencies and pool-impact bps before forwarding to `_beginSwap`.
    function _beginSwapFromKey(address sender, PoolKey calldata key, SwapParams calldata params)
        private
        returns (SwapEvaluation memory)
    {
        return _beginSwap(
            sender,
            SwapCurrencies.inputToken(key, params),
            SwapCurrencies.specifiedToken(key, params),
            SwapCurrencies.abs(params.amountSpecified),
            SwapCurrencies.poolImpactBps(poolManager, key, params)
        );
    }

    /// @dev Records settled volume using the specified currency and its post-swap delta.
    function _finishSwap(
        SwapEvaluation memory ev,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta
    ) private {
        _endSwap(ev, SwapCurrencies.specifiedToken(key, params), SwapCurrencies.settledSpecified(key, params, delta));
    }

    /// @dev Writes evaluation snapshot and FX rate into EIP-1153 transient storage for this pool.
    function _cacheStore(PoolKey calldata key, SwapEvaluation memory ev) private {
        SwapCache.store(key.toId(), ev.wallet, ev.token, ev.decision, ev.feeBps, ev.risk, ev.inflowTriggered);
        SwapCache.storeFx(key.toId(), ev.volumeFx.price, OracleQuote.pack(ev.volumeFx));
    }

    /// @dev Reads the evaluation snapshot and FX rate from transient storage for this pool.
    function _cacheLoad(PoolKey calldata key) private view returns (SwapEvaluation memory ev) {
        (ev.wallet, ev.token, ev.decision, ev.feeBps, ev.risk, ev.inflowTriggered) = SwapCache.load(key.toId());
        (uint256 price, uint256 packed) = SwapCache.loadFx(key.toId());
        ev.volumeFx = OracleQuote.unpack(price, packed);
    }

    /// @dev Takes the differential risk fee into FeeEscrow when all conditions are met:
    ///      FEE_OVERRIDE decision, escrow configured, and non-zero feeBps.
    function _maybeEscrow(
        SwapEvaluation memory ev,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta
    ) private returns (int128 hookDelta) {
        if (ev.decision == HookDecision.FEE_OVERRIDE && address(feeEscrow) != address(0) && ev.feeBps > 0) {
            hookDelta = _escrowRiskFee(ev.wallet, key, params, delta, ev.feeBps);
        }
    }
}
