// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISanctionRegistry} from "../interfaces/ISanctionRegistry.sol";
import {IComplianceOracle} from "../interfaces/IComplianceOracle.sol";
import {IRiskPolicy} from "../interfaces/IRiskPolicy.sol";
import {HookDecision} from "../libraries/HookDecision.sol";

/// @title Shared beforeSwap decision logic for AMLHook
/// @dev L1 → L2 → L3, plus §3.8 oracle-latency mitigations (unset / stale / pool activity).
abstract contract AmlHookLogic {
    ISanctionRegistry public immutable sanctionRegistry;
    IComplianceOracle public immutable complianceOracle;
    IRiskPolicy public immutable riskPolicy;

    /// @notice Max age of an oracle score before it may be treated as stale (seconds).
    uint64 public immutable maxScoreAge;
    /// @notice Rolling window for per-wallet pool activity counters (seconds).
    uint64 public immutable activityWindow;
    /// @notice Ops inside the activity window that force FEE_OVERRIDE instead of ALLOW.
    uint32 public immutable maxOpsInWindow;

    /// @dev Default punitive fee when elevating ALLOW due to latency mitigations (8%).
    uint24 public constant LATENCY_FEE_BPS = 800;

    struct PoolActivity {
        uint64 windowStart;
        uint32 opCount;
        uint64 lastSwapAt;
    }

    mapping(address => PoolActivity) internal _activity;

    error WalletBlocked(address wallet, uint8 score, string reason);
    error SanctionHit(address wallet);

    event SwapObserved(
        address indexed wallet,
        uint8 score,
        HookDecision decision,
        uint24 feeBps,
        uint8 hopDistance,
        address origin
    );

    event WalletBlockedEvent(address indexed wallet, uint8 score, string reason);

    /// @notice ALLOW was elevated to FEE_OVERRIDE by a §3.8 latency mitigation.
    event LatencyMitigationApplied(
        address indexed wallet, bytes32 reason, uint24 feeBps, uint8 oracleScore
    );

    bytes32 public constant REASON_SCORE_NEVER_WRITTEN = keccak256("SCORE_NEVER_WRITTEN");
    bytes32 public constant REASON_STALE_WITH_POOL_ACTIVITY = keccak256("STALE_WITH_POOL_ACTIVITY");
    bytes32 public constant REASON_ACTIVITY_WINDOW_CAP = keccak256("ACTIVITY_WINDOW_CAP");

    constructor(
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        uint64 maxScoreAge_,
        uint64 activityWindow_,
        uint32 maxOpsInWindow_
    ) {
        sanctionRegistry = sanctionRegistry_;
        complianceOracle = complianceOracle_;
        riskPolicy = riskPolicy_;
        maxScoreAge = maxScoreAge_ == 0 ? 5 minutes : maxScoreAge_;
        activityWindow = activityWindow_ == 0 ? 1 hours : activityWindow_;
        maxOpsInWindow = maxOpsInWindow_ == 0 ? 3 : maxOpsInWindow_;
    }

    /// @notice Per-wallet pool activity tracked by the hook (independent of the oracle).
    function poolActivity(address wallet)
        external
        view
        returns (uint64 windowStart, uint32 opCount, uint64 lastSwapAt)
    {
        PoolActivity storage a = _activity[wallet];
        return (a.windowStart, a.opCount, a.lastSwapAt);
    }

    /// @notice Evaluate a swap subject. Reverts on REVERT / sanctions.
    /// @return decision ALLOW or FEE_OVERRIDE
    /// @return feeBps Override fee when FEE_OVERRIDE; 0 on ALLOW
    /// @return risk Snapshot from the oracle
    function _evaluate(address wallet)
        internal
        view
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk
        )
    {
        if (sanctionRegistry.isSanctioned(wallet)) {
            revert SanctionHit(wallet);
        }

        risk = complianceOracle.getRisk(wallet);
        (decision, feeBps) = riskPolicy.decide(risk.score, risk.feeBps);

        if (decision == HookDecision.REVERT) {
            revert WalletBlocked(wallet, risk.score, "SCORE_REVERT_BAND");
        }

        if (decision == HookDecision.ALLOW) {
            (decision, feeBps) = _applyLatencyMitigations(wallet, risk);
        }
    }

    /// @dev Elevates ALLOW → FEE_OVERRIDE when oracle data is missing/stale or pool activity is high.
    function _applyLatencyMitigations(
        address wallet,
        IComplianceOracle.WalletRisk memory risk
    ) internal view returns (HookDecision decision, uint24 feeBps) {
        decision = HookDecision.ALLOW;
        feeBps = 0;

        // 1) Never written by keeper — distinguish from a legitimately low score.
        if (risk.updatedAt == 0) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }

        // 2) Stale oracle score + wallet has swapped in this pool since that write.
        if (_isStale(risk.updatedAt) && _hasPoolActivitySince(wallet, risk.updatedAt)) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }

        // 3) Hook-local activity cap inside the rolling window (oracle-independent).
        if (_opsInCurrentWindow(wallet) >= maxOpsInWindow) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }
    }

    /// @dev Same checks as view path, but emits LatencyMitigationApplied (for beforeSwap).
    function _evaluateWithMitigationEvents(address wallet)
        internal
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk
        )
    {
        if (sanctionRegistry.isSanctioned(wallet)) {
            revert SanctionHit(wallet);
        }

        risk = complianceOracle.getRisk(wallet);
        (decision, feeBps) = riskPolicy.decide(risk.score, risk.feeBps);

        if (decision == HookDecision.REVERT) {
            revert WalletBlocked(wallet, risk.score, "SCORE_REVERT_BAND");
        }

        if (decision != HookDecision.ALLOW) {
            return (decision, feeBps, risk);
        }

        if (risk.updatedAt == 0) {
            feeBps = _latencyFee(risk);
            emit LatencyMitigationApplied(wallet, REASON_SCORE_NEVER_WRITTEN, feeBps, risk.score);
            return (HookDecision.FEE_OVERRIDE, feeBps, risk);
        }

        if (_isStale(risk.updatedAt) && _hasPoolActivitySince(wallet, risk.updatedAt)) {
            feeBps = _latencyFee(risk);
            emit LatencyMitigationApplied(wallet, REASON_STALE_WITH_POOL_ACTIVITY, feeBps, risk.score);
            return (HookDecision.FEE_OVERRIDE, feeBps, risk);
        }

        if (_opsInCurrentWindow(wallet) >= maxOpsInWindow) {
            feeBps = _latencyFee(risk);
            emit LatencyMitigationApplied(wallet, REASON_ACTIVITY_WINDOW_CAP, feeBps, risk.score);
            return (HookDecision.FEE_OVERRIDE, feeBps, risk);
        }

        return (HookDecision.ALLOW, 0, risk);
    }

    function _latencyFee(IComplianceOracle.WalletRisk memory risk) private pure returns (uint24) {
        if (risk.feeBps > 0 && risk.feeBps <= 1000) return risk.feeBps;
        return LATENCY_FEE_BPS;
    }

    function _isStale(uint64 updatedAt) private view returns (bool) {
        return block.timestamp > uint256(updatedAt) + uint256(maxScoreAge);
    }

    function _hasPoolActivitySince(address wallet, uint64 updatedAt) private view returns (bool) {
        return _activity[wallet].lastSwapAt > updatedAt;
    }

    function _opsInCurrentWindow(address wallet) private view returns (uint32) {
        PoolActivity storage a = _activity[wallet];
        if (a.windowStart == 0) return 0;
        if (block.timestamp >= uint256(a.windowStart) + uint256(activityWindow)) return 0;
        return a.opCount;
    }

    /// @notice Record a successful pool swap for latency / activity mitigations (afterSwap).
    function _recordActivity(address wallet) internal {
        PoolActivity storage a = _activity[wallet];
        if (a.windowStart == 0 || block.timestamp >= uint256(a.windowStart) + uint256(activityWindow)) {
            a.windowStart = uint64(block.timestamp);
            a.opCount = 1;
        } else {
            unchecked {
                a.opCount += 1;
            }
        }
        a.lastSwapAt = uint64(block.timestamp);
    }

    /// @notice Emit afterSwap audit trail (called only when settlement succeeded).
    function _emitSwapObserved(
        address wallet,
        HookDecision decision,
        uint24 feeBps,
        IComplianceOracle.WalletRisk memory risk
    ) internal {
        emit SwapObserved(
            wallet, risk.score, decision, feeBps, risk.hopDistance, risk.origin
        );
    }
}
