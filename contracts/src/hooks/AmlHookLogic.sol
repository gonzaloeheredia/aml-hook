// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISanctionRegistry} from "../interfaces/ISanctionRegistry.sol";
import {IComplianceOracle} from "../interfaces/IComplianceOracle.sol";
import {IRiskPolicy} from "../interfaces/IRiskPolicy.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {HookDecision} from "../libraries/HookDecision.sol";

/// @title Shared beforeSwap decision logic for AMLHook
/// @dev L1 → L2 → L3, plus §3.8 oracle-latency mitigations (unset / stale / inflow / activity cap).
abstract contract AmlHookLogic {
    ISanctionRegistry public immutable sanctionRegistry;
    IComplianceOracle public immutable complianceOracle;
    IRiskPolicy public immutable riskPolicy;

    address public owner;

    /// @notice Max age of an oracle score before it is treated as stale (seconds).
    /// @dev Default 60s suits high-volume institutional pools (whitepaper §3.8 interval band).
    uint256 public stalenessThreshold;

    /// @notice Rolling window for per-wallet pool activity counters (seconds).
    uint64 public immutable activityWindow;

    /// @notice Ops inside the activity window that force FEE_OVERRIDE instead of ALLOW.
    uint32 public immutable maxOpsInWindow;

    /// @notice Balance-delta share (bps of current balance) that flags a significant inflow.
    /// @dev Default 5000 = 50%.
    uint256 public inflowThresholdBps;

    /// @dev Default punitive fee when elevating ALLOW due to hook-local latency mitigations (8%).
    uint24 public constant LATENCY_FEE_BPS = 800;

    struct PoolActivity {
        uint64 windowStart;
        uint32 opCount;
        uint64 lastSwapAt;
    }

    mapping(address => PoolActivity) internal _activity;

    /// @notice Last observed ERC-20 balance per wallet and token (inflow heuristic baseline).
    mapping(address => mapping(address => uint256)) public lastKnownBalance;

    /// @notice Timestamp when `lastKnownBalance` was last written for wallet/token.
    mapping(address => mapping(address => uint256)) public lastKnownBalanceTimestamp;

    error NotOwner();
    error WalletBlocked(address wallet, uint8 score, string reason);
    error SanctionHit(address wallet);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event StalenessThresholdUpdated(uint256 previous, uint256 current);
    event InflowThresholdUpdated(uint256 previous, uint256 current);

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

    /// @notice Significant balance increase detected while the oracle score predates that baseline.
    event InflowHeuristicTriggered(address indexed wallet, uint256 deltaBps, uint256 timestamp);

    bytes32 public constant REASON_SCORE_NEVER_WRITTEN = keccak256("SCORE_NEVER_WRITTEN");
    bytes32 public constant REASON_STALE_WITH_POOL_ACTIVITY = keccak256("STALE_WITH_POOL_ACTIVITY");
    bytes32 public constant REASON_ACTIVITY_WINDOW_CAP = keccak256("ACTIVITY_WINDOW_CAP");

    constructor(
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        uint256 stalenessThreshold_,
        uint64 activityWindow_,
        uint32 maxOpsInWindow_
    ) {
        sanctionRegistry = sanctionRegistry_;
        complianceOracle = complianceOracle_;
        riskPolicy = riskPolicy_;
        owner = msg.sender;
        // 60s default: high-volume institutional keeper band (whitepaper §3.8).
        stalenessThreshold = stalenessThreshold_ == 0 ? 60 : stalenessThreshold_;
        activityWindow = activityWindow_ == 0 ? 1 hours : activityWindow_;
        maxOpsInWindow = maxOpsInWindow_ == 0 ? 3 : maxOpsInWindow_;
        inflowThresholdBps = 5000;
        emit OwnershipTransferred(address(0), msg.sender);
        emit StalenessThresholdUpdated(0, stalenessThreshold);
        emit InflowThresholdUpdated(0, inflowThresholdBps);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setStalenessThreshold(uint256 stalenessThreshold_) external onlyOwner {
        emit StalenessThresholdUpdated(stalenessThreshold, stalenessThreshold_);
        stalenessThreshold = stalenessThreshold_;
    }

    function setInflowThresholdBps(uint256 inflowThresholdBps_) external onlyOwner {
        emit InflowThresholdUpdated(inflowThresholdBps, inflowThresholdBps_);
        inflowThresholdBps = inflowThresholdBps_;
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
    /// @param wallet End-user compliance subject.
    /// @param token Input token of the swap (address(0) skips the inflow heuristic).
    /// @return decision ALLOW or FEE_OVERRIDE
    /// @return feeBps Override fee when FEE_OVERRIDE; 0 on ALLOW
    /// @return risk Snapshot from the oracle
    function _evaluate(address wallet, address token)
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
        uint32 operationCount = _opsInCurrentWindow(wallet);
        bool isStale = _isStale(risk.updatedAt);
        (bool hasSignificantInflow,) = _inflowSignal(wallet, token, risk.updatedAt);

        (decision, feeBps) = riskPolicy.decide(
            risk.score, risk.feeBps, isStale, operationCount, hasSignificantInflow
        );

        if (decision == HookDecision.REVERT) {
            revert WalletBlocked(wallet, risk.score, "SCORE_REVERT_BAND");
        }

        if (decision == HookDecision.ALLOW) {
            (decision, feeBps) = _applyHookLocalMitigations(wallet, risk);
        }
    }

    /// @dev Elevates ALLOW → FEE_OVERRIDE for hook-local signals not passed into RiskPolicy
    ///      (never-written score; activity-window cap). Stale+activity and inflow floors live in RiskPolicy.
    function _applyHookLocalMitigations(
        address wallet,
        IComplianceOracle.WalletRisk memory risk
    ) internal view returns (HookDecision decision, uint24 feeBps) {
        decision = HookDecision.ALLOW;
        feeBps = 0;

        if (risk.updatedAt == 0) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }

        if (_opsInCurrentWindow(wallet) >= maxOpsInWindow) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }
    }

    /// @dev Same checks as view path, but emits mitigation / inflow events (for beforeSwap).
    function _evaluateWithMitigationEvents(address wallet, address token)
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
        uint32 operationCount = _opsInCurrentWindow(wallet);
        bool isStale = _isStale(risk.updatedAt);
        (bool hasSignificantInflow, uint256 deltaBps) =
            _inflowSignal(wallet, token, risk.updatedAt);

        (decision, feeBps) = riskPolicy.decide(
            risk.score, risk.feeBps, isStale, operationCount, hasSignificantInflow
        );

        if (decision == HookDecision.REVERT) {
            revert WalletBlocked(wallet, risk.score, "SCORE_REVERT_BAND");
        }

        if (hasSignificantInflow) {
            emit InflowHeuristicTriggered(wallet, deltaBps, block.timestamp);
        }

        // Audit when RiskPolicy floored ALLOW→FEE_OVERRIDE via stale+activity (score still in ALLOW band).
        if (
            risk.score <= 30 && isStale && operationCount > 0
                && decision == HookDecision.FEE_OVERRIDE
        ) {
            emit LatencyMitigationApplied(
                wallet, REASON_STALE_WITH_POOL_ACTIVITY, feeBps, risk.score
            );
        }

        if (decision != HookDecision.ALLOW) {
            return (decision, feeBps, risk);
        }

        if (risk.updatedAt == 0) {
            feeBps = _latencyFee(risk);
            emit LatencyMitigationApplied(wallet, REASON_SCORE_NEVER_WRITTEN, feeBps, risk.score);
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
        if (updatedAt == 0) return true;
        return block.timestamp > uint256(updatedAt) + stalenessThreshold;
    }

    /// @notice Balance-delta inflow heuristic for oracle-latency Mitigation 3.
    /// @dev Extra external call: `token.balanceOf(wallet)` in beforeSwap. Cold ERC-20 balanceOf is
    ///      typically ~2.1k–2.6k gas; warm slot reads are lower. This is the structural gas cost of
    ///      keeping a pool-local baseline so the hook can bound exposure while the keeper catches up
    ///      (whitepaper §3.8). Skipped when `token` is address(0).
    function _inflowSignal(address wallet, address token, uint64 scoreUpdatedAt)
        private
        view
        returns (bool hasSignificantInflow, uint256 deltaBps)
    {
        if (token == address(0) || token.code.length == 0) {
            return (false, 0);
        }

        uint256 currentBalance = IERC20Minimal(token).balanceOf(wallet);
        if (currentBalance == 0) {
            return (false, 0);
        }

        uint256 previous = lastKnownBalance[wallet][token];
        uint256 delta = currentBalance > previous ? currentBalance - previous : 0;
        deltaBps = (delta * 10_000) / currentBalance;

        // Oracle must still predate the last known baseline; a fresher score means the keeper
        // already had a chance to incorporate post-inflow information.
        uint256 baselineTs = lastKnownBalanceTimestamp[wallet][token];
        if (deltaBps > inflowThresholdBps && uint256(scoreUpdatedAt) <= baselineTs) {
            hasSignificantInflow = true;
        }
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

    /// @notice Refresh the inflow-heuristic baseline after a successful swap (afterSwap).
    function _updateKnownBalance(address wallet, address token) internal {
        if (token == address(0) || token.code.length == 0) return;
        uint256 bal = IERC20Minimal(token).balanceOf(wallet);
        lastKnownBalance[wallet][token] = bal;
        lastKnownBalanceTimestamp[wallet][token] = block.timestamp;
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
