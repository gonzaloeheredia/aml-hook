// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISanctionRegistry} from "../interfaces/ISanctionRegistry.sol";
import {IComplianceOracle} from "../interfaces/IComplianceOracle.sol";
import {IRiskPolicy} from "../interfaces/IRiskPolicy.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {HookDecision} from "../libraries/HookDecision.sol";

/// @title Shared beforeSwap decision logic for AMLHook
/// @notice Implements the read path in whitepaper §3.5: L1 → L2 → derived latency signals → L3,
///         plus hook-local §3.8 elevations (never-written score, activity-window cap).
/// @dev Pool-local state (activity window, lastKnownBalance) closes the keeper-latency gap
///      while RiskPolicy stays a pure mapping. Mitigations elevate ALLOW → FEE_OVERRIDE only.
///      Subject resolution prefers a trusted router (`IMsgSender`) over bare hookData.
abstract contract AmlHookLogic {
    ISanctionRegistry public immutable sanctionRegistry;
    IComplianceOracle public immutable complianceOracle;
    IRiskPolicy public immutable riskPolicy;

    address public owner;

    /// @notice Routers allowed to report the end-user via `IMsgSender.msgSender()`.
    mapping(address => bool) public trustedRouters;

    /// @notice Max age of an oracle score before it is treated as stale (seconds).
    /// @dev Default 60s suits high-volume institutional pools (whitepaper §3.8 interval band).
    uint256 public stalenessThreshold;

    /// @notice Rolling window for per-wallet pool activity counters (seconds).
    /// @dev Mitigation C (§3.8): burst ops across consecutive blocks while the keeper lags.
    uint64 public immutable activityWindow;

    /// @notice Ops inside the activity window that force FEE_OVERRIDE instead of ALLOW.
    uint32 public immutable maxOpsInWindow;

    /// @notice Balance-delta share (bps of current balance) that flags a significant inflow.
    /// @dev Default 5000 = 50% — Mitigation D (§3.8) / use-case Wallet D.
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
    /// @notice No verified end-user from trusted router or hookData (fail-closed §3.5).
    error MissingSwapSubject();
    /// @notice Trusted router subject and hookData address disagree.
    /// @param declared Address decoded from hookData (cross-check).
    /// @param fromRouter Address returned by `IMsgSender.msgSender()` on the trusted router.
    error SubjectMismatch(address declared, address fromRouter);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event StalenessThresholdUpdated(uint256 previous, uint256 current);
    event InflowThresholdUpdated(uint256 previous, uint256 current);
    event TrustedRouterUpdated(address indexed router, bool trusted);

    /// @notice afterSwap audit trail for off-chain scoring + reporting (§3.4 / §3.6 / §3.9 Step 7).
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

    /// @notice Significant balance increase detected while the oracle score predates that baseline (Mitigation D).
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

    /// @notice Owner retunes Mitigation B staleness window (§3.8; institutional vs retail pools).
    function setStalenessThreshold(uint256 stalenessThreshold_) external onlyOwner {
        emit StalenessThresholdUpdated(stalenessThreshold, stalenessThreshold_);
        stalenessThreshold = stalenessThreshold_;
    }

    /// @notice Owner retunes Mitigation D inflow threshold in bps of current balance (§3.8).
    function setInflowThresholdBps(uint256 inflowThresholdBps_) external onlyOwner {
        emit InflowThresholdUpdated(inflowThresholdBps, inflowThresholdBps_);
        inflowThresholdBps = inflowThresholdBps_;
    }

    /// @notice Owner grants or revokes trusted-router status (same admin pattern as SanctionRegistry).
    /// @dev Enablement criterion is an operational off-chain fact, not verified on-chain by this
    ///      contract. Before calling with `trusted = true`, the owner must confirm that `router`
    ///      belongs to a curated list of direct integrators (e.g. Uniswap Labs routers and other
    ///      protocols with a known integration relationship) and that its `IMsgSender.msgSender()`
    ///      implementation was reviewed to return the real end-user and that no third party can
    ///      overwrite that value within the same transaction. The contract cannot enforce these
    ///      properties; the guarantee depends on the owner's audit process prior to this call.
    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        trustedRouters[router] = trusted;
        emit TrustedRouterUpdated(router, trusted);
    }

    /// @notice Resolve the compliance subject for beforeSwap.
    /// @dev Trusted router is the primary source of truth: when the PoolManager-reported swap
    ///      initiator (`router` — that call's `msg.sender` to `PoolManager.swap`) is registered,
    ///      `IMsgSender(router).msgSender()` is invoked in try/catch and a non-zero return is the
    ///      verified end-user. When `hookData` also encodes a non-zero address, it is a cross-check
    ///      only — mismatch reverts `SubjectMismatch(declared, fromRouter)`. If the router is
    ///      untrusted, the call fails, or returns zero, fall back to decoding `abi.encode(endUser)`
    ///      from hookData (`MissingSwapSubject` if absent). Never scores the router itself.
    /// @param router PoolManager-reported swap initiator (`sender` in beforeSwap).
    /// @param hookData Optional `abi.encode(endUser)` cross-check / legacy fallback.
    function _resolveWallet(address router, bytes calldata hookData)
        internal
        view
        returns (address wallet)
    {
        if (trustedRouters[router]) {
            address fromRouter;
            try IMsgSender(router).msgSender() returns (address subject) {
                fromRouter = subject;
            } catch {
                // External call failed — fall through to hookData path.
            }
            if (fromRouter != address(0)) {
                address declared = _tryDecodeHookSubject(hookData);
                if (declared != address(0) && declared != fromRouter) {
                    revert SubjectMismatch(declared, fromRouter);
                }
                return fromRouter;
            }
        }

        wallet = _tryDecodeHookSubject(hookData);
        if (wallet == address(0)) revert MissingSwapSubject();
    }

    /// @dev Best-effort decode of `abi.encode(address)` from hookData; zero if missing/invalid.
    function _tryDecodeHookSubject(bytes calldata hookData) private pure returns (address subject) {
        if (hookData.length < 32) return address(0);
        subject = abi.decode(hookData, (address));
    }

    /// @notice Per-wallet pool activity tracked by the hook (independent of the oracle; Mitigation C).
    function poolActivity(address wallet)
        external
        view
        returns (uint64 windowStart, uint32 opCount, uint64 lastSwapAt)
    {
        PoolActivity storage a = _activity[wallet];
        return (a.windowStart, a.opCount, a.lastSwapAt);
    }

    /// @notice Evaluate a swap subject (view path). Reverts on REVERT / sanctions.
    /// @param wallet End-user compliance subject from hookData — not the router (§3.5).
    /// @param token Input token of the swap (address(0) skips the inflow heuristic).
    /// @return decision ALLOW or FEE_OVERRIDE
    /// @return feeBps Override fee when FEE_OVERRIDE; 0 on ALLOW
    /// @return risk Snapshot from the oracle
    /// @dev Pipeline: L1 `isSanctioned` → L2 `getRisk` → derive isStale / ops / inflow →
    ///      L3 `RiskPolicy.decide` → hook-local Mitigations A & C if still ALLOW.
    function _evaluate(address wallet, address token)
        internal
        view
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk
        )
    {
        // Layer 1 — static sanctions (§3.2): fail closed, no score read on hit.
        if (sanctionRegistry.isSanctioned(wallet)) {
            revert SanctionHit(wallet);
        }

        // Layer 2 — cached behavioral score (§3.2 / §3.8): hook never computes score on-chain.
        risk = complianceOracle.getRisk(wallet);
        uint32 operationCount = _opsInCurrentWindow(wallet);
        bool isStale = _isStale(risk.updatedAt);
        (bool hasSignificantInflow,) = _inflowSignal(wallet, token, risk.updatedAt);

        // Layer 3 — ternary decision + floors B/D (§3.3 / §3.8).
        (decision, feeBps) = riskPolicy.decide(
            risk.score, risk.feeBps, isStale, operationCount, hasSignificantInflow
        );

        if (decision == HookDecision.REVERT) {
            revert WalletBlocked(wallet, risk.score, "SCORE_REVERT_BAND");
        }

        // Mitigations A (never written) and C (activity-window cap) stay hook-local.
        if (decision == HookDecision.ALLOW) {
            (decision, feeBps) = _applyHookLocalMitigations(wallet, risk);
        }
    }

    /// @dev Elevates ALLOW → FEE_OVERRIDE for hook-local signals not passed into RiskPolicy
    ///      (Mitigation A: never-written score; Mitigation C: activity-window cap).
    ///      Stale+activity (B) and inflow (D) floors live in RiskPolicy.decide.
    function _applyHookLocalMitigations(
        address wallet,
        IComplianceOracle.WalletRisk memory risk
    ) internal view returns (HookDecision decision, uint24 feeBps) {
        decision = HookDecision.ALLOW;
        feeBps = 0;

        // Mitigation A: updatedAt == 0 means unknown wallet, not confirmed-clean score 0.
        if (risk.updatedAt == 0) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }

        // Mitigation C: burst activity in the rolling window while keeper score may lag.
        if (_opsInCurrentWindow(wallet) >= maxOpsInWindow) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }
    }

    /// @dev Same checks as `_evaluate`, but emits mitigation / inflow events for beforeSwap audit trail.
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

        // Mitigation D audit: generic recent-funds pattern, not origin attribution (§3.8).
        if (hasSignificantInflow) {
            emit InflowHeuristicTriggered(wallet, deltaBps, block.timestamp);
        }

        // Audit when RiskPolicy floored ALLOW→FEE_OVERRIDE via Mitigation B (score still ≤ 30).
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

        // Mitigation A — never written: clean wallets must be published with score 0 + non-zero updatedAt.
        if (risk.updatedAt == 0) {
            feeBps = _latencyFee(risk);
            emit LatencyMitigationApplied(wallet, REASON_SCORE_NEVER_WRITTEN, feeBps, risk.score);
            return (HookDecision.FEE_OVERRIDE, feeBps, risk);
        }

        // Mitigation C — activity-window cap.
        if (_opsInCurrentWindow(wallet) >= maxOpsInWindow) {
            feeBps = _latencyFee(risk);
            emit LatencyMitigationApplied(wallet, REASON_ACTIVITY_WINDOW_CAP, feeBps, risk.score);
            return (HookDecision.FEE_OVERRIDE, feeBps, risk);
        }

        return (HookDecision.ALLOW, 0, risk);
    }

    /// @dev Prefer keeper feeBps; else 8% latency fee (Wallet D / §3.8 designed product behavior).
    function _latencyFee(IComplianceOracle.WalletRisk memory risk) private pure returns (uint24) {
        if (risk.feeBps > 0 && risk.feeBps <= 1000) return risk.feeBps;
        return LATENCY_FEE_BPS;
    }

    /// @dev Mitigation B freshness check: score older than `stalenessThreshold` is stale.
    function _isStale(uint64 updatedAt) private view returns (bool) {
        if (updatedAt == 0) return true;
        return block.timestamp > uint256(updatedAt) + stalenessThreshold;
    }

    /// @notice Balance-delta inflow heuristic — oracle-latency Mitigation D (§3.8 / Wallet D).
    /// @dev Closes the gap A–C leave open: wallet published clean (score 0, updatedAt ≠ 0),
    ///      receives a large P2P transfer, swaps before keeper `updateScore`. Compares
    ///      `token.balanceOf(wallet)` to `lastKnownBalance`; if delta share > inflowThresholdBps
    ///      and oracle `updatedAt` still predates the baseline, passes hasSignificantInflow.
    ///      Extra gas for balanceOf is intentional. Skipped when `token` is address(0).
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
        // already had a chance to incorporate post-inflow information (N-hop scoring remains off-chain).
        uint256 baselineTs = lastKnownBalanceTimestamp[wallet][token];
        if (deltaBps > inflowThresholdBps && uint256(scoreUpdatedAt) <= baselineTs) {
            hasSignificantInflow = true;
        }
    }

    /// @dev Ops counted inside the current Mitigation C window (0 if window elapsed / never started).
    function _opsInCurrentWindow(address wallet) private view returns (uint32) {
        PoolActivity storage a = _activity[wallet];
        if (a.windowStart == 0) return 0;
        if (block.timestamp >= uint256(a.windowStart) + uint256(activityWindow)) return 0;
        return a.opCount;
    }

    /// @notice Record a successful pool swap for latency / activity mitigations (afterSwap; §3.8 / §3.9 Step 7).
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

    /// @notice Refresh the Mitigation D baseline after a successful swap (afterSwap; §3.8).
    function _updateKnownBalance(address wallet, address token) internal {
        if (token == address(0) || token.code.length == 0) return;
        uint256 bal = IERC20Minimal(token).balanceOf(wallet);
        lastKnownBalance[wallet][token] = bal;
        lastKnownBalanceTimestamp[wallet][token] = block.timestamp;
    }

    /// @notice Emit afterSwap audit trail once settlement succeeded (§3.6 reporting input / §3.4 film update).
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
