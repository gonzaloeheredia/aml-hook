// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookGovernance} from "./AmlHookGovernance.sol";
import {AmlHookLogic} from "./AmlHookLogic.sol";
import {AmlHookSettlement} from "./AmlHookSettlement.sol";
import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IFeeEscrow} from "../../interfaces/escrow/IFeeEscrow.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";
import {SwapCache} from "../../libraries/SwapCache.sol";
import {SwapCurrencies} from "../../libraries/SwapCurrencies.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title AMLHook — Uniswap v4 callbacks only. Risk lives in AmlHookLogic / RiskPolicy.
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
        uint64 activityWindow_
    )
        AmlHookSettlement(poolManager_, feeEscrow_)
        AmlHookGovernance(
            accessManager_, sanctionRegistry_, complianceOracle_, riskPolicy_, stalenessThreshold_, activityWindow_
        )
    {}

    function approveFailedDepositRefund(address wallet, address token, bool approved) external restricted {
        _setFailedDepositRefundApproval(wallet, token, approved);
    }

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

    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _requireNotPaused();
        _requireNotSanctioned(sender);
        return this.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        return this.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        SwapEvaluation memory ev = _beginSwap(
            sender,
            SwapCurrencies.inputToken(key, params),
            SwapCurrencies.specifiedToken(key, params),
            SwapCurrencies.abs(params.amountSpecified),
            SwapCurrencies.poolImpactBps(poolManager, key, params)
        );
        SwapCache.store(key.toId(), ev.wallet, ev.token, ev.decision, ev.feeBps, ev.risk, ev.inflowTriggered);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

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

        _endSwap(ev, SwapCurrencies.specifiedToken(key, params), SwapCurrencies.settledSpecified(key, params, delta));

        int128 hookDelta = 0;
        if (ev.decision == HookDecision.FEE_OVERRIDE && address(feeEscrow) != address(0) && ev.feeBps > 0) {
            hookDelta = _escrowRiskFee(ev.wallet, key, params, delta, ev.feeBps);
        }
        return (this.afterSwap.selector, hookDelta);
    }
}
