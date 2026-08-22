// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookLogic} from "./AmlHookLogic.sol";
import {AmlHookSettlement} from "./AmlHookSettlement.sol";
import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IFeeEscrow} from "../../interfaces/escrow/IFeeEscrow.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";
import {SwapCache} from "../../libraries/SwapCache.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @title AMLHook — Uniswap v4 callback surface
/// @notice Wires PoolManager callbacks to compliance (`AmlHookLogic`) and fee take (`AmlHookSettlement`).
/// @dev This contract must not decide risk or compute the differential. It only:
///        beforeSwap  → `_beginSwap` + cache
///        afterSwap   → `_endSwap` + optional `_escrowRiskFee`
///        liquidity   → pause / L1 sanctions on add; exits always open
contract AmlHook is AmlHookSettlement, AmlHookLogic {
    using PoolIdLibrary for PoolKey;

    constructor(
        IPoolManager poolManager_,
        address accessManager_,
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        IFeeEscrow feeEscrow_,
        uint256 stalenessThreshold_,
        uint64 activityWindow_,
        uint32 maxOpsInWindow_
    )
        AmlHookSettlement(poolManager_, feeEscrow_)
        AmlHookLogic(
            accessManager_,
            sanctionRegistry_,
            complianceOracle_,
            riskPolicy_,
            stalenessThreshold_,
            activityWindow_,
            maxOpsInWindow_
        )
    {}

    /// @inheritdoc BaseHook
    /// @notice beforeSwap + afterSwap + afterSwapReturnDelta (required to take the risk fee),
    ///         plus beforeAddLiquidity (pause + sanctions on LP entry) and beforeRemoveLiquidity
    ///         (always permitted — no sanction or pause gate).
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    /// @notice Blocks a sanctioned wallet from entering as a liquidity provider.
    /// @dev In Uniswap v4 the liquidity-hook `sender` is the PoolManager `msg.sender` of
    ///      `modifyLiquidity` — the LP itself. There is no router intermediary, so the
    ///      subject is `sender` directly (not `_resolveWallet`). Pause stops new exposure
    ///      (swaps and new LP deposits); exits stay open in `_beforeRemoveLiquidity`.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        _requireNotPaused();
        _requireNotSanctioned(sender);
        return this.beforeAddLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    /// @notice LP exit is always permitted — no sanction or pause gate here.
    /// @dev M-02: not screening sanctions on removal is a deliberate legal choice of
    ///      non-confiscation: capital already in the pool must remain withdrawable.
    ///      This is pending confirmation by compliance counsel. Do not add a sanctions
    ///      check here until that definition is written and a recovery path exists.
    function _beforeRemoveLiquidity(
        address /* sender */,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        return this.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    /// @notice Point-of-execution control before funds move (§3.9 Step 5).
    /// @dev On FEE_OVERRIDE we intentionally return lpFee = 0 so the pool keeps its
    ///      standard fee. The risk differential is collected in afterSwap → FeeEscrow.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        SwapEvaluation memory ev = _beginSwap(
            sender, _inputToken(key, params), _specifiedToken(key, params), _absAmount(params.amountSpecified)
        );
        SwapCache.store(key.toId(), ev.wallet, ev.token, ev.decision, ev.feeBps, ev.risk, ev.inflowTriggered);

        // ALLOW and FEE_OVERRIDE: do not override pool LP fee (standard path).
        // REVERT already reverted inside evaluate.
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc BaseHook
    /// @notice afterSwap: compliance memory first, then optional FeeEscrow take (§3.7 / §3.9 Step 7).
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, int128) {
        SwapEvaluation memory ev;
        (ev.wallet, ev.token, ev.decision, ev.feeBps, ev.risk, ev.inflowTriggered) = SwapCache.load(key.toId());
        SwapCache.clear(key.toId());

        _endSwap(ev, _specifiedToken(key, params), _settledSpecifiedAmount(key, params, delta));

        int128 hookDelta = 0;
        if (ev.decision == HookDecision.FEE_OVERRIDE && address(feeEscrow) != address(0) && ev.feeBps > 0) {
            hookDelta = _escrowRiskFee(ev.wallet, key, params, delta, ev.feeBps);
        }

        return (this.afterSwap.selector, hookDelta);
    }

    /// @dev Input currency of this swap — used by §3.8 Mitigation D.
    function _inputToken(PoolKey calldata key, SwapParams calldata params)
        private
        pure
        returns (address)
    {
        Currency c = params.zeroForOne ? key.currency0 : key.currency1;
        return Currency.unwrap(c);
    }

    /// @dev Currency of `amountSpecified`: input on exact-in, output on exact-out.
    function _specifiedToken(PoolKey calldata key, SwapParams calldata params)
        private
        pure
        returns (address)
    {
        bool exactIn = params.amountSpecified < 0;
        Currency c = exactIn
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);
        return Currency.unwrap(c);
    }

    /// @dev Absolute value of a Uniswap signed amount (`amountSpecified` or a balance delta).
    function _absAmount(int256 amount) private pure returns (uint256) {
        return amount < 0 ? uint256(-amount) : uint256(amount);
    }

    /// @dev Settled size of the specified currency after the swap (native units, no USD).
    function _settledSpecifiedAmount(PoolKey calldata, SwapParams calldata params, BalanceDelta delta)
        private
        pure
        returns (uint256)
    {
        bool exactIn = params.amountSpecified < 0;
        bool useToken0 = exactIn ? params.zeroForOne : !params.zeroForOne;
        int256 settled = useToken0 ? delta.amount0() : delta.amount1();
        return _absAmount(settled);
    }
}
