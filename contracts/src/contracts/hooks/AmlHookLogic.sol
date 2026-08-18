// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IMsgSender} from "../../interfaces/external/IMsgSender.sol";
import {IERC20Minimal} from "../../interfaces/external/IERC20Minimal.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";

/// @title Shared beforeSwap decision logic for AMLHook
/// @notice This is where the whitepaper's on-chain read path lives (§3.5 / §3.8 / §3.9).
///
/// @dev ═══════════════════════════════════════════════════════════════════════
///      READER'S GUIDE (why this contract exists)
///      ═══════════════════════════════════════════════════════════════════════
///
///      Uniswap v4 calls the hook at swap time. The hook must answer in the same
///      transaction: ALLOW (base fee), FEE_OVERRIDE (punitive/proportional fee),
///      or REVERT. It must NOT recompute the behavioral graph on-chain — that work
///      is off-chain (Oracle Keeper / COA). On-chain we only:
///        1) resolve WHO is swapping (end-user, never the router as subject),
///        2) screen L1 sanctions → read L2 score → decide L3 ternary,
///        3) close the keeper-latency gap with pool-local §3.8 signals.
///
///      Layers (whitepaper §3.2):
///        L1 SanctionRegistry  — static OFAC-style list; hit = REVERT before score
///        L2 ComplianceOracle  — keeper-written score / hop / feeBps / updatedAt
///        L3 RiskPolicy        — pure mapping score(+floors) → decision + fee
///        Hook-local           — Mitigations A & C (never-written, activity cap)
///                               Mitigations B & D are floors inside RiskPolicy
///
///      Why pool-local state? If the keeper has not yet published after a P2P
///      transfer (use-case Wallet D), a stale score 0 would wrongly ALLOW.
///      Activity counters + lastKnownBalance let the hook elevate ALLOW→FEE_OVERRIDE
///      without waiting for the oracle. Elevations never soften REVERT.
///
///      Governance: `AccessManaged` against the shared AccessManager.
///      `_HOOK_GOVERNOR` may retune thresholds / trusted routers only — not the
///      swap path itself (that is fixed in bytecode).
abstract contract AmlHookLogic is AccessManaged {
    ISanctionRegistry public immutable sanctionRegistry;
    IComplianceOracle public immutable complianceOracle;
    IRiskPolicy public immutable riskPolicy;

    /// @notice Routers allowed to report the end-user via `IMsgSender.msgSender()`.
    /// @dev Why: PoolManager's `sender` is usually the router, not the user. Scoring
    ///      the router would either bypass control (clean router) or block everyone
    ///      (contaminated router). Trusted routers implement `msgSender()` so we score
    ///      the real economic actor (§3.5).
    mapping(address => bool) public trustedRouters;

    /// @notice Max age of an oracle score before it is treated as stale (seconds).
    /// @dev Mitigation B (§3.8). Default 60s = high-volume institutional keeper band.
    ///      Retail pools may raise this via `_HOOK_GOVERNOR`.
    uint256 public stalenessThreshold;

    /// @notice Rolling window for per-wallet pool activity counters (seconds).
    /// @dev Mitigation C (§3.8): catch burst swaps across consecutive blocks while
    ///      the keeper has not yet moved the score tier.
    uint64 public immutable activityWindow;

    /// @notice Ops inside the activity window that force FEE_OVERRIDE instead of ALLOW.
    /// @dev Why a cap: without it, an attacker can spam ALLOW swaps under a lagging
    ///      clean score. Default 3 matches the local deploy / whitepaper example.
    uint32 public immutable maxOpsInWindow;

    /// @notice Balance-delta share (bps of current balance) that flags a significant inflow.
    /// @dev Mitigation D (§3.8) / use-case Wallet D. Default 5000 = 50%.
    ///      Detects "large new funds then immediate swap" — not fund origin (N-hop does that).
    uint256 public inflowThresholdBps;

    /// @dev Default punitive fee when elevating ALLOW due to hook-local latency mitigations.
    ///      800 bps = 8% — designed product fee when keeper omitted `feeBps` (Wallet D path).
    ///      Same constant as RiskPolicy (`FeeBps.LATENCY`) so A/C cannot drift from B/D.
    uint24 public constant LATENCY_FEE_BPS = FeeBps.LATENCY;

    /// @dev Per-wallet pool activity for Mitigation C. Independent of the oracle so the
    ///      hook can still elevate while `updateScore` is pending.
    struct PoolActivity {
        uint64 windowStart;
        uint32 opCount;
        uint64 lastSwapAt;
    }

    mapping(address => PoolActivity) internal _activity;

    /// @notice Last observed ERC-20 balance per wallet and token (inflow heuristic baseline).
    /// @dev Written in afterSwap so the *next* beforeSwap can measure a sudden increase.
    mapping(address => mapping(address => uint256)) public lastKnownBalance;

    /// @notice Timestamp when `lastKnownBalance` was last written for wallet/token.
    /// @dev Compared to oracle `updatedAt`: if the score is older than this baseline,
    ///      the keeper has not yet incorporated the inflow → Mitigation D can fire.
    mapping(address => mapping(address => uint256)) public lastKnownBalanceTimestamp;

    error WalletBlocked(address wallet, uint8 score, string reason);
    error SanctionHit(address wallet);
    /// @notice Caller is not a trusted router — no end-user can be resolved (fail-closed §3.5).
    error MissingSwapSubject();
    /// @notice Trusted router `msgSender()` reverted or returned zero — fail closed.
    error TrustedRouterSubjectFailed(address router);
    error InflowThresholdOutOfRange();

    event StalenessThresholdUpdated(uint256 previous, uint256 current);
    event InflowThresholdUpdated(uint256 previous, uint256 current);
    event TrustedRouterUpdated(address indexed router, bool trusted);

    /// @notice afterSwap audit trail for off-chain scoring + reporting (§3.4 / §3.6 / §3.9 Step 7).
    /// @dev This is the "film" the COA watches: who swapped, at what score/decision/fee/hop.
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
    /// @dev Reason codes let operators / regulators see *why* friction was applied
    ///      without a score-band FEE_OVERRIDE.
    event LatencyMitigationApplied(
        address indexed wallet, bytes32 reason, uint24 feeBps, uint8 oracleScore
    );

    /// @notice Significant balance increase detected while the oracle score predates that baseline (Mitigation D).
    event InflowHeuristicTriggered(address indexed wallet, uint256 deltaBps, uint256 timestamp);

    bytes32 public constant REASON_SCORE_NEVER_WRITTEN = keccak256("SCORE_NEVER_WRITTEN");
    bytes32 public constant REASON_STALE_WITH_POOL_ACTIVITY = keccak256("STALE_WITH_POOL_ACTIVITY");
    bytes32 public constant REASON_ACTIVITY_WINDOW_CAP = keccak256("ACTIVITY_WINDOW_CAP");

    constructor(
        address accessManager_,
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        uint256 stalenessThreshold_,
        uint64 activityWindow_,
        uint32 maxOpsInWindow_
    ) AccessManaged(accessManager_) {
        sanctionRegistry = sanctionRegistry_;
        complianceOracle = complianceOracle_;
        riskPolicy = riskPolicy_;
        // Sensible defaults if deploy passes 0 (whitepaper §3.8 institutional band).
        stalenessThreshold = stalenessThreshold_ == 0 ? 60 : stalenessThreshold_;
        activityWindow = activityWindow_ == 0 ? 1 hours : activityWindow_;
        maxOpsInWindow = maxOpsInWindow_ == 0 ? 3 : maxOpsInWindow_;
        inflowThresholdBps = 5000; // 50% — Wallet D / Mitigation D default
        emit StalenessThresholdUpdated(0, stalenessThreshold);
        emit InflowThresholdUpdated(0, inflowThresholdBps);
    }

    /// @notice Hook governor retunes Mitigation B staleness window (§3.8).
    /// @dev Why restricted: only `_HOOK_GOVERNOR` should change how aggressively we treat
    ///      lagging scores (institutional 30–60s vs retail minutes). Keepers must not.
    function setStalenessThreshold(uint256 stalenessThreshold_) external restricted {
        emit StalenessThresholdUpdated(stalenessThreshold, stalenessThreshold_);
        stalenessThreshold = stalenessThreshold_;
    }

    /// @notice Hook governor retunes Mitigation D inflow threshold in bps of current balance (§3.8).
    /// @dev Floor `FeeBps.MIN_INFLOW_THRESHOLD` (1%) so a zero threshold cannot elevate every dust delta.
    function setInflowThresholdBps(uint256 inflowThresholdBps_) external restricted {
        if (
            inflowThresholdBps_ < FeeBps.MIN_INFLOW_THRESHOLD
                || inflowThresholdBps_ > FeeBps.MAX_INFLOW_THRESHOLD
        ) {
            revert InflowThresholdOutOfRange();
        }
        emit InflowThresholdUpdated(inflowThresholdBps, inflowThresholdBps_);
        inflowThresholdBps = inflowThresholdBps_;
    }

    /// @notice Hook governor grants or revokes trusted-router status.
    /// @dev Enablement is an *operational attestation*, not an on-chain proof (§3.5).
    ///      Before `trusted = true`, the governor must have reviewed that `router`:
    ///        - is a curated integrator (e.g. Uniswap Labs router), and
    ///        - `msgSender()` returns the real end-user and cannot be overwritten in-tx.
    ///      The contract only stores that attestation.
    function setTrustedRouter(address router, bool trusted) external restricted {
        trustedRouters[router] = trusted;
        emit TrustedRouterUpdated(router, trusted);
    }

    /// @notice Resolve the compliance subject for beforeSwap (§3.5).
    /// @dev The only subject source is `IMsgSender(router).msgSender()` on a trusted router.
    ///      Uniswap `hookData` is ignored: callers cannot declare the end-user.
    ///      Untrusted initiator → `MissingSwapSubject`. Revert or zero msgSender →
    ///      `TrustedRouterSubjectFailed`. Never score the router itself.
    /// @param router PoolManager-reported swap initiator (`sender` in beforeSwap).
    function _resolveWallet(address router) internal view returns (address wallet) {
        if (!trustedRouters[router]) revert MissingSwapSubject();

        try IMsgSender(router).msgSender() returns (address subject) {
            wallet = subject;
        } catch {
            revert TrustedRouterSubjectFailed(router);
        }
        if (wallet == address(0)) revert TrustedRouterSubjectFailed(router);
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
    /// @param wallet End-user compliance subject — not the router (§3.5).
    /// @param token Input token of the swap (address(0) skips the inflow heuristic).
    /// @return decision ALLOW or FEE_OVERRIDE
    /// @return feeBps Override fee when FEE_OVERRIDE; 0 on ALLOW
    /// @return risk Snapshot from the oracle
    /// @dev PIPELINE (same order as whitepaper §3.5 / §3.9 Step 5):
    ///      L1 isSanctioned → L2 getRisk → derive isStale / ops / inflow →
    ///      L3 RiskPolicy.decide → if still ALLOW, apply hook-local A & C.
    function _evaluate(address wallet, address token)
        internal
        view
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk
        )
    {
        (decision, feeBps, risk,) = _evaluateCore(wallet, token);
        if (decision == HookDecision.ALLOW) {
            (decision, feeBps) = _applyHookLocalMitigations(wallet, risk);
        }
    }

    /// @dev Shared L1 → L3 path. Hook-local A/C are applied by the caller so the view
    ///      and event-emitting wrappers cannot drift.
    struct EvalSignals {
        bool isStale;
        uint32 operationCount;
        bool hasSignificantInflow;
        uint256 deltaBps;
    }

    function _evaluateCore(address wallet, address token)
        private
        view
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            EvalSignals memory sig
        )
    {
        // ── Layer 1 — static sanctions (§3.2 / §4.1) ─────────────────────────
        // Fail closed: OFAC/SDN-style hit must not consult the behavioral score.
        if (sanctionRegistry.isSanctioned(wallet)) {
            revert SanctionHit(wallet);
        }

        // ── Layer 2 — keeper-written score (§3.2 / §3.8) ─────────────────────
        // Hook never computes N-hop decay here; it only reads what the keeper published.
        risk = complianceOracle.getRisk(wallet);

        // Derive §3.8 signals the pure RiskPolicy cannot observe by itself
        // (RiskPolicy must stay free of block.timestamp / external calls).
        sig.operationCount = _opsInCurrentWindow(wallet);
        sig.isStale = _isStale(risk.updatedAt);
        (sig.hasSignificantInflow, sig.deltaBps) = _inflowSignal(wallet, token, risk.updatedAt);

        // ── Layer 3 — ternary bands + floors B/D (§3.3 / §3.8) ───────────────
        (decision, feeBps) = riskPolicy.decide(
            risk.score, risk.feeBps, sig.isStale, sig.operationCount, sig.hasSignificantInflow
        );

        // High band (71–100) or policy REVERT: unconditional block (§3.3 Output 3).
        if (decision == HookDecision.REVERT) {
            revert WalletBlocked(wallet, risk.score, "SCORE_REVERT_BAND");
        }
    }

    /// @dev Elevates ALLOW → FEE_OVERRIDE for hook-local signals not passed into RiskPolicy.
    ///      A: never-written score (unknown ≠ confirmed-clean).
    ///      C: activity-window cap (burst while keeper lags).
    ///      B (stale+ops) and D (inflow) already floored inside RiskPolicy.decide.
    function _applyHookLocalMitigations(
        address wallet,
        IComplianceOracle.WalletRisk memory risk
    ) internal view returns (HookDecision decision, uint24 feeBps) {
        decision = HookDecision.ALLOW;
        feeBps = 0;

        // Mitigation A: updatedAt == 0 means "never published", not "score 0 clean".
        // A legitimately clean wallet must be written explicitly with score 0 + non-zero updatedAt.
        if (risk.updatedAt == 0) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }

        // Mitigation C: too many ops in the rolling window → economic friction, not hard block.
        if (_opsInCurrentWindow(wallet) >= maxOpsInWindow) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }
    }

    /// @dev Same checks as `_evaluate`, but emits mitigation / inflow events for the audit trail.
    ///      Used by beforeSwap so operators can prove *why* FEE_OVERRIDE was applied (§3.6).
    function _evaluateWithMitigationEvents(address wallet, address token)
        internal
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk
        )
    {
        EvalSignals memory sig;
        (decision, feeBps, risk, sig) = _evaluateCore(wallet, token);

        // Mitigation D audit: generic "recent funds → swap" pattern (not origin attribution).
        if (sig.hasSignificantInflow) {
            emit InflowHeuristicTriggered(wallet, sig.deltaBps, block.timestamp);
        }

        // Audit when RiskPolicy floored ALLOW→FEE_OVERRIDE via Mitigation B (score still ≤ 30).
        if (
            risk.score <= 30 && sig.isStale && sig.operationCount > 0
                && decision == HookDecision.FEE_OVERRIDE
        ) {
            emit LatencyMitigationApplied(
                wallet, REASON_STALE_WITH_POOL_ACTIVITY, feeBps, risk.score
            );
        }

        if (decision != HookDecision.ALLOW) {
            return (decision, feeBps, risk);
        }

        (decision, feeBps) = _applyHookLocalMitigations(wallet, risk);
        if (decision == HookDecision.ALLOW) {
            return (decision, 0, risk);
        }

        bytes32 reason = risk.updatedAt == 0 ? REASON_SCORE_NEVER_WRITTEN : REASON_ACTIVITY_WINDOW_CAP;
        emit LatencyMitigationApplied(wallet, reason, feeBps, risk.score);
        return (decision, feeBps, risk);
    }

    /// @dev Prefer keeper-written feeBps when in range; else 8% latency fee
    ///      (Wallet D / §3.8 designed product behavior when keeper omitted fee).
    function _latencyFee(IComplianceOracle.WalletRisk memory risk) private pure returns (uint24) {
        return FeeBps.resolveLatencyFee(risk.feeBps);
    }

    /// @dev Mitigation B freshness: score older than `stalenessThreshold` is stale.
    ///      updatedAt == 0 is also treated stale (overlaps Mitigation A's "never written").
    function _isStale(uint64 updatedAt) private view returns (bool) {
        if (updatedAt == 0) return true;
        return block.timestamp > uint256(updatedAt) + stalenessThreshold;
    }

    /// @notice Balance-delta inflow heuristic — oracle-latency Mitigation D (§3.8 / Wallet D).
    /// @dev WHY: Mitigations A–C miss the path "wallet was published clean, then receives a large
    ///      P2P transfer, then swaps before keeper updateScore". We compare token.balanceOf(wallet)
    ///      to lastKnownBalance; if the delta share exceeds inflowThresholdBps AND the oracle's
    ///      updatedAt still predates the baseline, we signal hasSignificantInflow to RiskPolicy.
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
        // Share of *current* balance that appeared since the last baseline (in bps).
        deltaBps = (delta * 10_000) / currentBalance;

        // If the keeper already wrote after the baseline, N-hop / typology had a chance to run —
        // do not double-apply the heuristic on top of a fresh score.
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

    /// @notice Record a successful pool swap for latency / activity mitigations (afterSwap; §3.9 Step 7).
    /// @dev Why afterSwap (not beforeSwap): only count ops that actually settled. Resets the
    ///      rolling window when it has elapsed so old bursts do not permanently elevate.
    function _recordActivity(address wallet) internal {
        PoolActivity storage a = _activity[wallet];
        if (a.windowStart == 0 || block.timestamp >= uint256(a.windowStart) + uint256(activityWindow)) {
            a.windowStart = uint64(block.timestamp);
            a.opCount = 1;
        } else {
            a.opCount += 1;
        }
        a.lastSwapAt = uint64(block.timestamp);
    }

    /// @notice Refresh the Mitigation D baseline after a successful swap (afterSwap; §3.8).
    /// @dev So the *next* beforeSwap measures inflow against post-swap reality, not a stale baseline.
    function _updateKnownBalance(address wallet, address token) internal {
        if (token == address(0) || token.code.length == 0) return;
        uint256 bal = IERC20Minimal(token).balanceOf(wallet);
        lastKnownBalance[wallet][token] = bal;
        lastKnownBalanceTimestamp[wallet][token] = block.timestamp;
    }

    /// @notice Emit afterSwap audit trail once settlement succeeded (§3.6 / §3.4).
    /// @dev Off-chain engine consumes this to update the wallet's cumulative risk before the next swap.
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
