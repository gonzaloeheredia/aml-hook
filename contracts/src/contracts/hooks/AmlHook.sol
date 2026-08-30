// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookActivity} from "./AmlHookActivity.sol";
import {AmlHookGovernance} from "./AmlHookGovernance.sol";
import {AmlHookGovernanceBase} from "./AmlHookGovernanceBase.sol";
import {AmlHookSettlement} from "./AmlHookSettlement.sol";
import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IFeeEscrow} from "../../interfaces/escrow/IFeeEscrow.sol";
import {IComplianceTreasury} from "../../interfaces/treasury/IComplianceTreasury.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";
import {LiquidityCache} from "../../libraries/LiquidityCache.sol";
import {SwapCurrencies} from "../../libraries/SwapCurrencies.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Minimal interface for DELEGATECALL dispatch to AmlHookSatellite.
interface IAmlHookSatellite {
    function satelliteBeginSwap(address sender, PoolKey calldata key, SwapParams calldata params) external;
    function satelliteEndSwap(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        external returns (HookDecision decision, address wallet, uint24 feeBps);
    function satelliteGuardAddLiquidity(address sender)
        external returns (address wallet, bool viaRouter, bool neverScored, HookDecision decision, uint24 feeBps, uint8 score);
    function satelliteEvaluateNeverScoredAdd(
        address wallet, bool viaRouter, address token0, address token1,
        uint256 amount0, uint256 amount1, uint256 impact
    ) external returns (HookDecision decision, uint24 feeBps);
    function satelliteEvaluateRemoveLiquidity(address sender)
        external returns (address wallet, bool seize, uint8 score, bool viaRouter);
}

/// @title AmlHook: Uniswap v4 AML hook entry-point (satellite edition)
/// @notice Thin hook shell that owns settlement state and compliance window accumulators.
///         All swap / LP evaluation logic and governance setters live in AmlHookSatellite,
///         called via DELEGATECALL so the satellite runs in AmlHook's storage context.
///
/// @dev Storage layout prefix (matches AmlHookSatellite exactly, enabling safe DELEGATECALL):
///      [0]   AccessManaged + Pausable (packed)
///      [1..] AmlHookGovernanceBase + AmlHookActivity
///      [N..] AmlHookSettlement (feeEscrow, treasury, seize / failed-deposit)
///      [M]   AmlHook._initialized + _satellite (packed)
///
///      Settlement MUST come last in the inheritance list. Listing it first put
///      `complianceTreasury` in the satellite's `sanctionRegistry` slot, so every
///      DELEGATECALL guard called `isSanctioned` on the treasury and reverted.
///
///      Governance setters (setStalenessThreshold, proposeX / applyX, etc.) and logic
///      view functions (previewSwap, observeSwap, syncBaseline) are routed to the satellite
///      through the fallback, which DELEGATECALL-forwards any unknown selector.
contract AmlHook is AmlHookActivity, AmlHookGovernance, AmlHookSettlement {
    using PoolIdLibrary for PoolKey;

    bool private _initialized;
    address private _satellite;

    error AlreadyInitialized();

    constructor(IPoolManager poolManager_, address accessManager_)
        AmlHookSettlement(poolManager_)
        AmlHookGovernanceBase(accessManager_)
    {}

    // -------------------------------------------------------------------------
    // Initialisation
    // -------------------------------------------------------------------------

    /// @notice One-time wiring of the satellite and compliance dependencies.
    ///         Must be called immediately after CREATE2 deploy.
    /// @param satellite_          Deployed AmlHookSatellite address (same poolManager).
    /// @param sanctionRegistry_   Layer 1 sanctions list.
    /// @param complianceOracle_   Layer 2 COA score store.
    /// @param riskPolicy_         Layer 3 pure decision contract.
    /// @param feeEscrow_          48-hour escrow for fee differentials and seized LP exits.
    /// @param complianceTreasury_ Ledged compliance fund.
    /// @param stalenessThreshold_ Score staleness cutoff (0 → DEFAULT_STALENESS).
    /// @param activityWindow_     Rolling window for op-count / USD accumulators (0 → default).
    function initialize(
        address satellite_,
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
        _satellite = satellite_;
        _initSettlement(feeEscrow_, complianceTreasury_);
        _initGovernance(sanctionRegistry_, complianceOracle_, riskPolicy_, stalenessThreshold_, activityWindow_);
    }

    /// @notice Governor grants or revokes a subject's right to reclaim a failed-deposit for `token`.
    function approveFailedDepositRefund(address wallet, address token, bool approved) external restricted {
        _setFailedDepositRefundApproval(wallet, token, approved);
    }

    // -------------------------------------------------------------------------
    // Hook permissions
    // -------------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    // -------------------------------------------------------------------------
    // Uniswap v4 callbacks: dispatch evaluation to satellite via DELEGATECALL
    // -------------------------------------------------------------------------

    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal override returns (bytes4)
    {
        bytes memory ret = _delegatecall(
            abi.encodeCall(IAmlHookSatellite.satelliteGuardAddLiquidity, (sender))
        );
        (address wallet, bool viaRouter, bool neverScored, HookDecision decision, uint24 feeBps, uint8 score) =
            abi.decode(ret, (address, bool, bool, HookDecision, uint24, uint8));
        LiquidityCache.store(key.toId(), wallet, false, score, viaRouter, neverScored, decision, feeBps);
        return this.beforeAddLiquidity.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, BalanceDelta) {
        (address wallet, , , bool viaRouter, bool neverScored, HookDecision decision, uint24 feeBps) =
            LiquidityCache.load(key.toId());
        LiquidityCache.clear(key.toId());
        if (neverScored) {
            bytes memory ret = _delegatecall(abi.encodeCall(
                IAmlHookSatellite.satelliteEvaluateNeverScoredAdd,
                (
                    wallet, viaRouter,
                    Currency.unwrap(key.currency0), Currency.unwrap(key.currency1),
                    SwapCurrencies.abs(int256(delta.amount0())),
                    SwapCurrencies.abs(int256(delta.amount1())),
                    SwapCurrencies.addImpactBps(poolManager, key, delta)
                )
            ));
            (decision, feeBps) = abi.decode(ret, (HookDecision, uint24));
        }
        BalanceDelta hookDelta = BalanceDelta.wrap(0);
        if (decision == HookDecision.FEE_OVERRIDE && feeBps > 0) {
            hookDelta = _escrowAddRiskFee(wallet, key, delta, feeBps);
        }
        _updateKnownBalance(wallet, Currency.unwrap(key.currency0), false);
        _updateKnownBalance(wallet, Currency.unwrap(key.currency1), false);
        return (this.afterAddLiquidity.selector, hookDelta);
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        bytes memory ret = _delegatecall(
            abi.encodeCall(IAmlHookSatellite.satelliteEvaluateRemoveLiquidity, (sender))
        );
        (address wallet, bool seize, uint8 score, bool viaRouter) =
            abi.decode(ret, (address, bool, uint8, bool));
        LiquidityCache.store(
            key.toId(), wallet, seize, score, viaRouter, false,
            seize ? HookDecision.REVERT : HookDecision.ALLOW, 0
        );
        return this.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, BalanceDelta) {
        (address wallet, bool seize,,,,,) = LiquidityCache.load(key.toId());
        LiquidityCache.clear(key.toId());
        if (!seize) return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
        return (this.afterRemoveLiquidity.selector, _seizeLpExit(wallet, key, params, delta, feesAccrued));
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        _delegatecall(abi.encodeCall(IAmlHookSatellite.satelliteBeginSwap, (sender, key, params)));
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, int128) {
        bytes memory ret = _delegatecall(
            abi.encodeCall(IAmlHookSatellite.satelliteEndSwap, (key, params, delta))
        );
        (HookDecision decision, address wallet, uint24 feeBps) =
            abi.decode(ret, (HookDecision, address, uint24));
        int128 hookDelta;
        if (decision == HookDecision.FEE_OVERRIDE && address(feeEscrow) != address(0) && feeBps > 0) {
            hookDelta = _escrowRiskFee(wallet, key, params, delta, feeBps);
        }
        return (this.afterSwap.selector, hookDelta);
    }

    // -------------------------------------------------------------------------
    // Fallback: routes governance setters and logic view functions to satellite
    // -------------------------------------------------------------------------

    /// @dev Forwards any selector not implemented directly on AmlHook to the satellite
    ///      via DELEGATECALL. This covers all AmlHookGovernance setters (setStalenessThreshold,
    ///      proposeX / applyX, pause, etc.) as well as AmlHookLogic public functions
    ///      (previewSwap, observeSwap, syncBaseline).
    fallback() external payable {
        address sat = _satellite;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), sat, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}

    // -------------------------------------------------------------------------
    // Internal helper
    // -------------------------------------------------------------------------

    function _delegatecall(bytes memory data) private returns (bytes memory ret) {
        address sat = _satellite;
        bool ok;
        (ok, ret) = sat.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
