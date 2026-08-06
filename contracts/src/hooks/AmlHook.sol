// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./BaseHook.sol";
import {AmlHookLogic} from "./AmlHookLogic.sol";
import {ISanctionRegistry} from "../interfaces/ISanctionRegistry.sol";
import {IComplianceOracle} from "../interfaces/IComplianceOracle.sol";
import {IRiskPolicy} from "../interfaces/IRiskPolicy.sol";
import {HookDecision} from "../libraries/HookDecision.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/// @title AMLHook — Uniswap v4 compliance hook (REAL on-chain logic)
/// @notice PoolManager → beforeSwap/afterSwap → SanctionRegistry → ComplianceOracle → RiskPolicy
/// @dev Swap subject MUST be `abi.encode(endUser)` in hookData — never the router.
///      §3.8 mitigations: unset score, stale+activity, activity-window cap (see AmlHookLogic).
contract AmlHook is BaseHook, AmlHookLogic {
    using LPFeeLibrary for uint24;

    /// @notice Router called without encoding the end-user wallet in hookData.
    error MissingSwapSubject();

    /// @dev Transient cache so afterSwap can emit without a second oracle read race.
    address private _swapWallet;
    HookDecision private _swapDecision;
    uint24 private _swapFeeBps;
    IComplianceOracle.WalletRisk private _swapRisk;

    constructor(
        IPoolManager poolManager_,
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        uint64 maxScoreAge_,
        uint64 activityWindow_,
        uint32 maxOpsInWindow_
    )
        BaseHook(poolManager_)
        AmlHookLogic(
            sanctionRegistry_,
            complianceOracle_,
            riskPolicy_,
            maxScoreAge_,
            activityWindow_,
            maxOpsInWindow_
        )
    {}

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(address /* sender */, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address wallet = _resolveWallet(hookData);
        (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk) =
            _evaluateWithMitigationEvents(wallet);

        _swapWallet = wallet;
        _swapDecision = decision;
        _swapFeeBps = feeBps;
        _swapRisk = risk;

        uint24 lpFee;
        if (decision == HookDecision.FEE_OVERRIDE) {
            lpFee = uint24(feeBps) * 100 | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        } else {
            lpFee = 0;
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee);
    }

    /// @inheritdoc BaseHook
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _recordActivity(_swapWallet);
        _emitSwapObserved(_swapWallet, _swapDecision, _swapFeeBps, _swapRisk);

        delete _swapWallet;
        delete _swapDecision;
        delete _swapFeeBps;
        delete _swapRisk;

        return (this.afterSwap.selector, 0);
    }

    function _resolveWallet(bytes calldata hookData) private pure returns (address wallet) {
        if (hookData.length < 32) revert MissingSwapSubject();
        wallet = abi.decode(hookData, (address));
        if (wallet == address(0)) revert MissingSwapSubject();
    }
}
