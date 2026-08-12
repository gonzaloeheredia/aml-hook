// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "../external/BaseHook.sol";
import {AmlHookLogic} from "./AmlHookLogic.sol";
import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @title AMLHook — Uniswap v4 compliance hook (REAL on-chain logic)
/// @notice Orchestrator at swap time (whitepaper §3.1 / §3.5 / §3.9):
///         PoolManager → beforeSwap / afterSwap → SanctionRegistry (L1) → ComplianceOracle (L2)
///         → RiskPolicy (L3). Does not compute behavioral scores off-chain; only reads/decides.
/// @dev Subject resolution: trusted router `IMsgSender.msgSender()` primary; hookData cross-check /
///      fallback (§3.5). §3.8 mitigations: never-written score, stale+activity, inflow, activity cap.
///
///      Governance for the thresholds and trusted-router list this contract exposes lives in
///      `AmlHookLogic`, which this contract inherits and which is `AccessManaged` against the same
///      manager as the registry and the oracle. This contract itself declares no restricted
///      function of its own; it only wires `beforeSwap` / `afterSwap` into that shared logic.
contract AmlHook is BaseHook, AmlHookLogic {
    using LPFeeLibrary for uint24;

    /// @dev Transient cache so afterSwap can emit the trail without a second oracle read race.
    address private _swapWallet;
    address private _swapToken;
    HookDecision private _swapDecision;
    uint24 private _swapFeeBps;
    IComplianceOracle.WalletRisk private _swapRisk;

    constructor(
        IPoolManager poolManager_,
        address accessManager_,
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        uint256 stalenessThreshold_,
        uint64 activityWindow_,
        uint32 maxOpsInWindow_
    )
        BaseHook(poolManager_)
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
    /// @notice Declares beforeSwap + afterSwap (+ dynamic fee) — the two intervention points in §3.1 / §3.9.
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
    /// @notice Point-of-execution control before funds move (§1.3 / §3.9 Step 5).
    /// @dev Resolves end-user (trusted router → hookData) → L1 → L2 → L3 + §3.8 floors.
    ///      On FEE_OVERRIDE returns `lpFee` with OVERRIDE_FEE_FLAG for the PoolManager.
    ///      On REVERT / SanctionHit / MissingSwapSubject / SubjectMismatch the swap reverts.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // `sender` = PoolManager.swap caller (router). Not the PoolManager; not the scored subject.
        address wallet = _resolveWallet(sender, hookData);
        address token = _inputToken(key, params);
        (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk) =
            _evaluateWithMitigationEvents(wallet, token);

        // Cache for afterSwap audit trail (SwapObserved) once settlement succeeds.
        _swapWallet = wallet;
        _swapToken = token;
        _swapDecision = decision;
        _swapFeeBps = feeBps;
        _swapRisk = risk;

        uint24 lpFee;
        if (decision == HookDecision.FEE_OVERRIDE) {
            // Dynamic fee for this swap only (Output 2 — §3.3); PoolManager applies override.
            lpFee = uint24(feeBps) * 100 | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        } else {
            lpFee = 0; // ALLOW → pool base fee (e.g. 0.30%); REVERT already reverted above.
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee);
    }

    /// @inheritdoc BaseHook
    /// @notice Layer 4 / memory write after a successful swap (§3.2 Layer 4, §3.4, §3.9 Step 7).
    /// @dev Updates pool-local activity + inflow baseline, then emits SwapObserved for the
    ///      off-chain scoring engine and reporting module. Structural difference vs static KYC hooks.
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _recordActivity(_swapWallet);
        _updateKnownBalance(_swapWallet, _swapToken);
        _emitSwapObserved(_swapWallet, _swapDecision, _swapFeeBps, _swapRisk);

        delete _swapWallet;
        delete _swapToken;
        delete _swapDecision;
        delete _swapFeeBps;
        delete _swapRisk;

        return (this.afterSwap.selector, 0);
    }

    /// @dev Input currency of this swap (direction from `zeroForOne`) — used by §3.8 Mitigation D
    ///      to compare `balanceOf` vs `lastKnownBalance` for the inflow heuristic.
    function _inputToken(PoolKey calldata key, SwapParams calldata params)
        private
        pure
        returns (address)
    {
        Currency c = params.zeroForOne ? key.currency0 : key.currency1;
        return Currency.unwrap(c);
    }
}
