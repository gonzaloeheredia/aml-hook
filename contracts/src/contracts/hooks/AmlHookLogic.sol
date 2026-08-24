// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookActivity} from "./AmlHookActivity.sol";

import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IMsgSender} from "../../interfaces/external/IMsgSender.sol";
import {IGnosisSafeOwners} from "../../interfaces/external/IGnosisSafeOwners.sol";
import {IERC20Minimal} from "../../interfaces/external/IERC20Minimal.sol";
import {IAggregatorV3} from "../../interfaces/external/IAggregatorV3.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";
import {UsdQuote} from "../../libraries/UsdQuote.sol";

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
///        Hook-local           — Mitigation A (never-written score → FEE_OVERRIDE)
///                               Floor C (daily USD aggregation → hard REVERT, inside _evaluateCore)
///                               Mitigations B & D are floors inside RiskPolicy
///                               A: never-scored USD (proportional / punitive / REVERT).
///                               B/D: published USD bands (pass / proportional / punitive).
///                               Quotes are Chainlink 8 decimals. Live fees sit on this hook.
///
///      Why pool-local state? If the keeper has not yet published after a P2P
///      transfer (use-case Wallet D), a stale score 0 would wrongly ALLOW.
///      Activity counters + lastKnownBalance let the hook elevate ALLOW→FEE_OVERRIDE
///      without waiting for the oracle. Elevations never soften REVERT.
///
///      Governance: `AccessManaged` against the shared AccessManager.
///      `_HOOK_GOVERNOR` retunes operational knobs / trusted routers.
///      `_COMPLIANCE_OFFICER` proposes then confirms USD floors, floor fees, and
///      the pool-impact cut (48h grant delay in Deploy). Neither role can rewrite
///      the swap path (fixed in bytecode). Score cuts 31 / 55 / 71 stay in RiskPolicy.
///
///      Uniswap-facing surface (AmlHook must use these, in this order):
///        `_beginSwap`  — resolve subject + L1/L2/L3 + mitigations A–D
///        `_endSwap`    — record activity, refresh inflow baseline, emit SwapObserved
///      Leaf helpers (`_evaluate*`, `_recordActivity`, `_updateKnownBalance`) stay
///      `internal` for the unit harness. Inverting `_endSwap`'s three steps, or
///      skipping `_beginSwap`, is a silent mitigation break — do not call the leaves
///      from the Uniswap callbacks.
abstract contract AmlHookLogic is AmlHookActivity {

    // ── Errors ────────────────────────────────────────────────────────────────

    error WalletBlocked(address wallet, uint8 score, string reason);
    error SanctionHit(address wallet);
    /// @notice Never-scored wallet: this swap's USD-8 is at/above `unscoredRevertThreshold`.
    /// @dev Index this selector on reverted txs — a log would be discarded by the revert
    ///      (same reason `WalletBlocked` / `SanctionHit` are errors, not events).
    error UnscoredMagnitudeBlocked(address wallet, uint256 assessedUsd, uint256 threshold);
    /// @notice Never-scored swap takes an anomalous share of the pool's active virtual reserve.
    error UnscoredPoolImpactBlocked(address wallet, uint256 poolImpactBps, uint256 threshold);
    /// @notice Floor C: prior 24h USD plus this swap crosses `unscoredRevertThreshold`.
    error DailyAggregationBlocked(address wallet, uint256 assessedUsd, uint256 threshold);
    /// @notice Magnitude quote failed (no feed, stale feed, or invalid answer). Fail-closed.
    error MagnitudeQuoteFailed(address token, bytes32 reason);
    /// @notice Trusted router `msgSender()` reverted or returned zero — fail closed.
    error TrustedRouterSubjectFailed(address router);

    // ── Events ────────────────────────────────────────────────────────────────

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

    /// @notice ALLOW was elevated to FEE_OVERRIDE by a §3.8 latency mitigation.
    /// @dev Reason codes let operators / regulators see *why* friction was applied
    ///      without a score-band FEE_OVERRIDE.
    event LatencyMitigationApplied(
        address indexed wallet, bytes32 reason, uint24 feeBps, uint8 oracleScore
    );

    /// @notice Significant balance increase detected while the oracle score predates that baseline (Mitigation D).
    event InflowHeuristicTriggered(address indexed wallet, uint256 deltaBps, uint256 timestamp);

    // ── Reason-code constants ─────────────────────────────────────────────────

    bytes32 public constant REASON_SCORE_NEVER_WRITTEN = keccak256("SCORE_NEVER_WRITTEN");
    bytes32 public constant REASON_STALE_WITH_POOL_ACTIVITY = keccak256("STALE_WITH_POOL_ACTIVITY");
    bytes32 public constant REASON_POOL_IMPACT = keccak256("POOL_IMPACT");
    bytes32 public constant QUOTE_NO_FEED = keccak256("NO_FEED");
    bytes32 public constant QUOTE_STALE_FEED = keccak256("STALE_FEED");
    bytes32 public constant QUOTE_BAD_PRICE = keccak256("BAD_PRICE");
    bytes32 public constant QUOTE_WINDOW_FAILED = keccak256("WINDOW_FAILED");

    // ── Swap snapshot (built by _beginSwap, consumed by _endSwap) ────────────

    struct SwapEvaluation {
        address wallet;
        address token;
        HookDecision decision;
        uint24 feeBps;
        IComplianceOracle.WalletRisk risk;
        bool inflowTriggered;
    }

    // ── Internal signals bundle (avoids deep stack in _evaluateCore) ──────────

    struct EvalSignals {
        bool isStale;
        uint32 operationCount;
        bool hasSignificantInflow;
        uint256 inflowShareBps;
        uint256 assessedUsd;
        uint256 inflowTokenDelta;
        uint256 inflowUsd;
    }

    // ── Uniswap-facing surface ────────────────────────────────────────────────

    /// @notice beforeSwap compliance entry: resolve the subject, then decide (events on).
    /// @dev Order is fixed here so AmlHook cannot evaluate a router as the subject or
    ///      skip mitigations. `token` is the swap input (address(0) skips Mitigation D).
    ///      `volumeToken` + `amount` are the specified-currency magnitude (native units).
    ///      `poolImpactBps` is the specified amount vs the active-tick virtual reserve (Floors A/B).
    function _beginSwap(
        address router,
        address token,
        address volumeToken,
        uint256 amount,
        uint256 poolImpactBps
    ) internal returns (SwapEvaluation memory eval) {
        eval.wallet = _resolveWallet(router);
        eval.token = token;
        (eval.decision, eval.feeBps, eval.risk, eval.inflowTriggered) =
            _evaluateWithMitigationEvents(eval.wallet, token, volumeToken, amount, poolImpactBps);
    }

    /// @notice afterSwap compliance exit: activity → baseline → SwapObserved, in that order.
    /// @dev Activity must land before the next beforeSwap sees Mitigation C / structuring
    ///      volume. Baseline must wait until after this swap's inflow flag is consumed (H-02).
    ///      Observation is last so the COA trail reflects the settled decision.
    function _endSwap(SwapEvaluation memory eval, address volumeToken, uint256 settledAmount) internal {
        _recordActivity(eval.wallet, volumeToken, settledAmount);
        _updateKnownBalance(eval.wallet, eval.token, eval.inflowTriggered);
        _emitSwapObserved(eval.wallet, eval.decision, eval.feeBps, eval.risk);
    }

    // ── Public views ──────────────────────────────────────────────────────────

    /// @notice Same L1→L3 path as beforeSwap, as a view. Reverts on REVERT / sanctions.
    /// @dev Quote / operator path. Does not record activity or move tokens. Not a Uniswap swap.
    function previewSwap(address wallet, address token, uint256 amount)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, token, token, amount, 0);
    }

    /// @notice Apply afterSwap bookkeeping (activity, baseline, SwapObserved) without a PoolManager.
    /// @dev Honest local demo: evaluate + record. Does not take pool tokens or pretend Uniswap settled.
    ///      Restricted to `_HOOK_GOVERNOR`. `_requireNotPaused()` is intentionally absent here:
    ///      governors must be able to inject observations even during an emergency pause to keep
    ///      the COA audit trail accurate. Off-chain monitors should account for events emitted
    ///      during a paused period and not treat them as evidence of permitted swap activity.
    function observeSwap(address wallet, address token, uint256 amount)
        external
        restricted
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        SwapEvaluation memory eval;
        eval.wallet = wallet;
        eval.token = token;
        (eval.decision, eval.feeBps, eval.risk, eval.inflowTriggered) =
            _evaluateWithMitigationEvents(wallet, token, token, amount, 0);
        _endSwap(eval, token, amount);
        return (eval.decision, eval.feeBps, eval.risk);
    }

    /// @notice Write `lastKnownBalance` to the current ERC-20 balance (Mitigation D baseline).
    /// @dev Local reset / seed. Restricted to `_HOOK_GOVERNOR`. Honors `minBaselineInterval`.
    function syncBaseline(address wallet, address token) external restricted {
        _updateKnownBalance(wallet, token, false);
    }

    // ── Subject resolution ────────────────────────────────────────────────────

    /// @notice Resolve the compliance subject for beforeSwap (§3.5).
    /// @dev The only subject source is `IMsgSender(router).msgSender()` on a trusted router.
    ///      Uniswap `hookData` is ignored: callers cannot declare the end-user.
    ///      Untrusted initiator → `MissingSwapSubject`. Revert or zero msgSender →
    ///      `TrustedRouterSubjectFailed`. Never score the router itself.
    ///      A contract subject must be a trusted multisig whose owners pass L1
    ///      (`_requireMultisigOwnersClean`). The returned wallet is still the Safe;
    ///      L2 score / Mitigations A–D run on that address, not per signer.
    /// @param router PoolManager-reported swap initiator (`sender` in beforeSwap).
    function _resolveWallet(address router) internal view returns (address wallet) {
        if (!trustedRouters[router]) revert MissingSwapSubject();

        try IMsgSender(router).msgSender() returns (address subject) {
            wallet = subject;
        } catch {
            revert TrustedRouterSubjectFailed(router);
        }
        if (wallet == address(0)) revert TrustedRouterSubjectFailed(router);

        if (wallet.code.length == 0) return wallet;

        TrustedMultisig memory ms = trustedMultisigs[wallet];
        if (!ms.trusted) revert MissingSwapSubject();
        _requireMultisigOwnersClean(wallet, ms.kind);
    }

    /// @notice Reverts if `wallet` is on the L1 sanctions list (§3.2 / §4.1).
    /// @dev Shared by the swap path (`_evaluateCore`) and LP entry (`AmlHook._beforeAddLiquidity`).
    ///      LP exit is not screened. Fail closed: a sanctions hit must never consult the
    ///      behavioral score or any other layer. Blocked swaps revert (`SanctionHit` /
    ///      `WalletBlocked`); off-chain monitors should index those custom errors on reverted
    ///      txs — a log would be discarded by the revert.
    function _requireNotSanctioned(address wallet) internal view {
        if (sanctionRegistry.isSanctioned(wallet)) revert SanctionHit(wallet);
    }

    // ── Evaluation pipeline ───────────────────────────────────────────────────

    /// @notice Evaluate a swap subject (view path). Reverts on REVERT / sanctions.
    /// @dev TEST-ONLY: called with amount=0, which bypasses _inflowSignal magnitude computation.
    ///      Do not use from production code paths where amount-sensitive compliance is required.
    function _evaluate(address wallet, address token)
        internal
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, token, token, 0, 0);
    }

    /// @notice View evaluate with specified-currency magnitude (`volumeToken` + `amount`).
    function _evaluate(address wallet, address token, address volumeToken, uint256 amount)
        internal
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, token, volumeToken, amount, 0);
    }

    function _evaluate(
        address wallet,
        address token,
        address volumeToken,
        uint256 amount,
        uint256 poolImpactBps
    )
        internal
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        _requireNotPaused();
        EvalSignals memory signals;
        (decision, feeBps, risk, signals) = _evaluateCore(wallet, token, volumeToken, amount, poolImpactBps);
        if (decision == HookDecision.ALLOW) {
            (decision, feeBps) = _applyHookLocalMitigations(risk);
        }
    }

    /// @dev Same checks as `_evaluate`, but emits mitigation / inflow events for the audit trail.
    ///      Used by beforeSwap so operators can prove *why* FEE_OVERRIDE was applied (§3.6).
    function _evaluateWithMitigationEvents(address wallet, address token)
        internal
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            bool inflowTriggered
        )
    {
        return _evaluateWithMitigationEvents(wallet, token, token, 0, 0);
    }

    /// @notice Live evaluate: same as `_evaluate` plus mitigation / inflow events for the audit trail.
    function _evaluateWithMitigationEvents(
        address wallet,
        address token,
        address volumeToken,
        uint256 amount
    )
        internal
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            bool inflowTriggered
        )
    {
        return _evaluateWithMitigationEvents(wallet, token, volumeToken, amount, 0);
    }

    function _evaluateWithMitigationEvents(
        address wallet,
        address token,
        address volumeToken,
        uint256 amount,
        uint256 poolImpactBps
    )
        internal
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            bool inflowTriggered
        )
    {
        _requireNotPaused();
        EvalSignals memory signals;
        (decision, feeBps, risk, signals) = _evaluateCore(wallet, token, volumeToken, amount, poolImpactBps);
        inflowTriggered = signals.hasSignificantInflow;

        // Mitigation D audit: inbound USD in the proportional / punitive band, or a >50% share (event only).
        if (
            signals.hasSignificantInflow
                || (unscoredFeeThreshold != 0 && signals.inflowUsd >= unscoredFeeThreshold)
        ) {
            emit InflowHeuristicTriggered(wallet, signals.inflowShareBps, block.timestamp);
        }

        // Never-scored USD bands are decided in RiskPolicy (live floor fees); emit the A reason here.
        if (risk.updatedAt == 0 && decision == HookDecision.FEE_OVERRIDE) {
            bytes32 mitigationReason = (poolImpactThresholdBps != 0 && poolImpactBps > poolImpactThresholdBps)
                ? REASON_POOL_IMPACT
                : REASON_SCORE_NEVER_WRITTEN;
            emit LatencyMitigationApplied(wallet, mitigationReason, feeBps, risk.score);
        }

        // Audit when RiskPolicy floored ALLOW→FEE_OVERRIDE via Mitigation B (score still ≤ 30).
        if (
            risk.score <= 30 && signals.isStale && signals.operationCount > 0
                && decision == HookDecision.FEE_OVERRIDE
        ) {
            bytes32 mitigationReason = (poolImpactThresholdBps != 0 && poolImpactBps > poolImpactThresholdBps)
                ? REASON_POOL_IMPACT
                : REASON_STALE_WITH_POOL_ACTIVITY;
            if (mitigationReason == REASON_POOL_IMPACT || (unscoredFeeThreshold != 0 && signals.assessedUsd >= unscoredFeeThreshold))
            {
                emit LatencyMitigationApplied(wallet, mitigationReason, feeBps, risk.score);
            }
        }

        if (decision != HookDecision.ALLOW) {
            return (decision, feeBps, risk, inflowTriggered);
        }

        (decision, feeBps) = _applyHookLocalMitigations(risk);
        if (decision == HookDecision.ALLOW) {
            return (decision, 0, risk, inflowTriggered);
        }

        emit LatencyMitigationApplied(wallet, REASON_SCORE_NEVER_WRITTEN, feeBps, risk.score);
        return (decision, feeBps, risk, inflowTriggered);
    }

    /// @dev Shared L1 → L3 path. Hook-local A/C are applied by the caller so the view
    ///      and event-emitting wrappers cannot drift.
    /// @dev PIPELINE (same order as whitepaper §3.5 / §3.9 Step 5):
    ///      L1 isSanctioned → L2 getRisk → derive isStale / ops / inflow / assessed volume →
    ///      L3 RiskPolicy.decide → Floor C hard-revert (`_enforceDailyAggregation`) → if still ALLOW, Mitigation A.
    function _evaluateCore(
        address wallet,
        address token,
        address volumeToken,
        uint256 amount,
        uint256 poolImpactBps
    )
        private
        view
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            EvalSignals memory signals
        )
    {
        // ── Layer 1 — static sanctions (§3.2 / §4.1) ─────────────────────────
        _requireNotSanctioned(wallet);

        // ── Layer 2 — keeper-written score (§3.2 / §3.8) ─────────────────────
        risk = complianceOracle.getRisk(wallet);

        signals.operationCount = _opsInCurrentWindow(wallet);
        signals.isStale = _isStale(risk.updatedAt);
        (signals.hasSignificantInflow, signals.inflowShareBps, signals.inflowTokenDelta) =
            _inflowSignal(wallet, token, risk.updatedAt);

        bool neverScored = risk.updatedAt == 0;
        if (neverScored) {
            (signals.assessedUsd,) = _requireUsdQuote(volumeToken, amount, 0);
            if (signals.inflowTokenDelta > 0) {
                (signals.inflowUsd,) = _requireUsdQuote(token, signals.inflowTokenDelta, 0);
            }
        } else {
            if (signals.inflowTokenDelta > 0) {
                (signals.inflowUsd,) = _requireUsdQuote(token, signals.inflowTokenDelta, 0);
                uint256 currentBalance = IERC20Minimal(token).balanceOf(wallet);
                (uint256 currentBalanceUsd,) = _requireUsdQuote(token, currentBalance, 0);
                if (currentBalanceUsd > 0) {
                    signals.inflowShareBps = (signals.inflowUsd * 10_000) / currentBalanceUsd;
                    signals.hasSignificantInflow = signals.inflowShareBps > inflowThresholdBps;
                } else {
                    signals.hasSignificantInflow = false;
                }
            }
            if (signals.isStale && signals.operationCount > 0) {
                (signals.assessedUsd,) = _requireUsdQuote(volumeToken, amount, _usdInCurrentWindow(wallet));
            }
        }

        // ── Layer 3 — RiskPolicy ternary (§3.2 / §3.3) ───────────────────────
        (decision, feeBps) = riskPolicy.decide(
            risk.score,
            risk.feeBps,
            signals.isStale,
            signals.operationCount,
            signals.hasSignificantInflow,
            neverScored,
            signals.assessedUsd,
            signals.inflowUsd,
            unscoredFeeThreshold,
            unscoredRevertThreshold,
            proportionalFeeBps,
            punitiveFeeBps
        );

        // ── Floor A extra — pool-drain guard for unknown wallet ───────────────
        if (
            neverScored && poolImpactThresholdBps != 0 && poolImpactBps > poolImpactThresholdBps
                && decision == HookDecision.FEE_OVERRIDE
        ) {
            if (feeBps >= punitiveFeeBps) {
                revert UnscoredPoolImpactBlocked(wallet, poolImpactBps, poolImpactThresholdBps);
            }
            feeBps = punitiveFeeBps;
        }

        // ── Floor B extra — stale+active swap draining active liquidity ───────
        // Hardens the band (pass → mid, mid → high) but never REVERTs. Ceiling is punitive fee.
        if (
            !neverScored && signals.isStale && signals.operationCount > 0
                && poolImpactThresholdBps != 0 && poolImpactBps > poolImpactThresholdBps
        ) {
            if (decision == HookDecision.ALLOW) {
                decision = HookDecision.FEE_OVERRIDE;
                feeBps = proportionalFeeBps;
            } else if (decision == HookDecision.FEE_OVERRIDE && feeBps < punitiveFeeBps) {
                feeBps = punitiveFeeBps;
            }
        }

        if (decision == HookDecision.REVERT) {
            if (neverScored) {
                revert UnscoredMagnitudeBlocked(wallet, signals.assessedUsd, unscoredRevertThreshold);
            }
            revert WalletBlocked(wallet, risk.score, "SCORE_REVERT_BAND");
        }

        // Floor C: prior 24h USD + this swap crosses the live high floor (several ops).
        // A single ticket at/above that floor is A/B/D, not C (`priorDaily == 0` on the first swap).
        // Score-band and A-magnitude REVERTs above win first.
        _enforceDailyAggregation(wallet, volumeToken, amount, neverScored, signals.assessedUsd);
    }

    /// @dev Elevates ALLOW → FEE_OVERRIDE for hook-local signals not passed into RiskPolicy.
    ///      A: never-written score (unknown ≠ confirmed-clean). Safety net if decide was the 5-arg form.
    ///      C is a hard block (`DailyAggregationBlocked`) inside `_evaluateCore`, not a fee.
    ///      B (stale+ops) and D (inflow) already floored inside RiskPolicy.decide.
    function _applyHookLocalMitigations(IComplianceOracle.WalletRisk memory risk)
        internal
        view
        returns (HookDecision decision, uint24 feeBps)
    {
        decision = HookDecision.ALLOW;
        feeBps = 0;

        // Mitigation A: updatedAt == 0 means "never published", not "score 0 clean".
        // A legitimately clean wallet must be written explicitly with score 0 + non-zero updatedAt.
        if (risk.updatedAt == 0) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }
    }

    /// @dev Floor C: the later swap that makes prior 24h USD + this swap cross
    ///      `unscoredRevertThreshold` REVERTs. A first swap of the day (`priorDaily == 0`)
    ///      is A/B/D only, even at the high floor. The `== 0` early-return is residual;
    ///      the setter cannot store a revert floor that is not strictly above the fee floor.
    function _enforceDailyAggregation(
        address wallet,
        address volumeToken,
        uint256 amount,
        bool neverScored,
        uint256 swapUsdIfQuoted
    ) private view {
        if (unscoredRevertThreshold == 0) return;
        uint256 priorDailyUsd = _usdInDailyWindow(wallet);
        if (priorDailyUsd == 0) return;
        if (priorDailyUsd == type(uint256).max) {
            revert MagnitudeQuoteFailed(volumeToken, QUOTE_WINDOW_FAILED);
        }
        uint256 swapUsd = swapUsdIfQuoted;
        if (!neverScored && amount > 0) {
            (swapUsd,) = _requireUsdQuote(volumeToken, amount, 0);
        }
        if (priorDailyUsd + swapUsd >= unscoredRevertThreshold) {
            revert DailyAggregationBlocked(wallet, priorDailyUsd + swapUsd, unscoredRevertThreshold);
        }
    }

    // ── USD quoting ───────────────────────────────────────────────────────────

    /// @dev Quote `amount` of `token` to USD-8 and add `windowUsd`. Reverts fail-closed on any quote error.
    function _requireUsdQuote(address token, uint256 amount, uint256 windowUsd)
        private
        view
        returns (uint256 totalUsd, bytes32 quoteError)
    {
        if (windowUsd == type(uint256).max) {
            revert MagnitudeQuoteFailed(token, QUOTE_WINDOW_FAILED);
        }
        (uint256 usd, bytes32 err) = _tryQuoteUsdRaw(token, amount);
        if (err != bytes32(0)) revert MagnitudeQuoteFailed(token, err);
        return (windowUsd + usd, bytes32(0));
    }

    /// @inheritdoc AmlHookActivity
    function _tryQuoteUsdRaw(address token, uint256 amount)
        internal
        view
        override
        returns (uint256 usd, bytes32 quoteError)
    {
        IAggregatorV3 feed = priceFeeds[token];
        if (address(feed) == address(0)) return (0, QUOTE_NO_FEED);

        uint80 roundId;
        int256 price;
        uint256 updatedAt;
        uint80 answeredInRound;
        try feed.latestRoundData() returns (uint80 rid, int256 p, uint256, uint256 u, uint80 air) {
            roundId = rid;
            price = p;
            updatedAt = u;
            answeredInRound = air;
        } catch {
            return (0, QUOTE_BAD_PRICE);
        }

        if (price <= 0 || updatedAt == 0 || answeredInRound < roundId) {
            return (0, QUOTE_BAD_PRICE);
        }
        if (block.timestamp > updatedAt + priceStalenessThreshold) {
            return (0, QUOTE_STALE_FEED);
        }

        uint8 feedDecimals;
        try feed.decimals() returns (uint8 decimals) {
            feedDecimals = decimals;
        } catch {
            return (0, QUOTE_BAD_PRICE);
        }
        if (feedDecimals > 18) return (0, QUOTE_BAD_PRICE);

        (uint8 tokenDecimals, bool decOk) = _tokenDecimals(token);
        if (!decOk) return (0, QUOTE_BAD_PRICE);

        usd = UsdQuote.toUsd8(amount, tokenDecimals, uint256(price), feedDecimals);
    }

    /// @dev Native ETH (`address(0)`) and no-code currencies are 18 decimals. ERC-20 `decimals()`
    ///      is fail-closed if missing or > 36. A feed is still required to quote.
    function _tokenDecimals(address token) private view returns (uint8 decimals_, bool ok) {
        if (token == address(0) || token.code.length == 0) return (18, true);
        try IERC20Minimal(token).decimals() returns (uint8 d) {
            if (d > 36) return (0, false);
            return (d, true);
        } catch {
            return (0, false);
        }
    }

    // ── Scoring helpers ───────────────────────────────────────────────────────

    /// @dev Prefer keeper-written `feeBps` when ≤ `MAX_OVERRIDE`; else the default
    ///      latency constant. Live A/B/D bands use `proportionalFeeBps` / `punitiveFeeBps`.
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
    ///      P2P transfer, then swaps before keeper updateScore". Token delta is quoted to USD-8.
    ///      Inbound USD is quoted for Floor D's pass / proportional / punitive bands. The 50% share is audit-only.
    ///      Extra gas for balanceOf is intentional. Skipped when `token` is address(0).
    function _inflowSignal(address wallet, address token, uint64 scoreUpdatedAt)
        private
        view
        returns (bool hasSignificantInflow, uint256 inflowShareBps, uint256 inflowTokenDelta)
    {
        if (token == address(0) || token.code.length == 0) {
            return (false, 0, 0);
        }

        uint256 currentBalance = IERC20Minimal(token).balanceOf(wallet);
        if (currentBalance == 0) {
            return (false, 0, 0);
        }

        uint256 previousBalance = lastKnownBalance[wallet][token];
        uint256 balanceDelta = currentBalance > previousBalance ? currentBalance - previousBalance : 0;
        // Provisional token-unit share; `_evaluateCore` overwrites with inbound USD / current USD.
        inflowShareBps = (balanceDelta * 10_000) / currentBalance;

        uint256 baselineTimestamp = lastKnownBalanceTimestamp[wallet][token];
        // Never-written: the whole current bag is inbound (Floor D on Wallet E).
        if (scoreUpdatedAt == 0) {
            return (false, inflowShareBps, currentBalance);
        }
        if (baselineTimestamp == 0) {
            return (false, 0, 0);
        }
        // Oracle already newer than the baseline: inflow was incorporated; do not fee or block on it.
        if (uint256(scoreUpdatedAt) > baselineTimestamp) {
            return (false, inflowShareBps, 0);
        }
        inflowTokenDelta = balanceDelta;
        if (inflowShareBps > inflowThresholdBps) {
            hasSignificantInflow = true;
        }
    }

    // ── Multisig helpers ──────────────────────────────────────────────────────

    /// @dev C-03 L1: enumerate Safe owners and apply `multisigAggregation` to sanctions only.
    ///      ALL_CLEAN: any sanctioned owner → `SanctionHit(owner)`.
    ///      ANY_CLEAN: one unsanctioned owner is enough; if every owner is sanctioned →
    ///      `SanctionHit` on the first sanctioned owner. No per-owner score / REVERT-band.
    function _requireMultisigOwnersClean(address wallet, MultisigType kind) private view {
        address[] memory owners;
        if (kind == MultisigType.GNOSIS_SAFE) {
            try IGnosisSafeOwners(wallet).getOwners() returns (address[] memory ownerList) {
                owners = ownerList;
            } catch {
                revert MissingSwapSubject();
            }
        } else {
            revert MissingSwapSubject();
        }
        if (owners.length == 0) revert MissingSwapSubject();

        bool anyOwnerClean;
        address firstSanctionedOwner;
        for (uint256 i; i < owners.length; ++i) {
            if (!sanctionRegistry.isSanctioned(owners[i])) {
                anyOwnerClean = true;
            } else {
                if (firstSanctionedOwner == address(0)) firstSanctionedOwner = owners[i];
                if (multisigAggregation == MultisigAggregation.ALL_CLEAN) {
                    revert SanctionHit(owners[i]);
                }
            }
        }
        if (multisigAggregation == MultisigAggregation.ANY_CLEAN && !anyOwnerClean) {
            revert SanctionHit(firstSanctionedOwner);
        }
    }

    // ── Audit trail ───────────────────────────────────────────────────────────

    /// @notice Emit afterSwap audit trail once settlement succeeded (§3.6 / §3.4).
    /// @dev Off-chain engine consumes this to update the wallet's cumulative risk before the next swap.
    function _emitSwapObserved(
        address wallet,
        HookDecision decision,
        uint24 feeBps,
        IComplianceOracle.WalletRisk memory risk
    ) internal {
        emit SwapObserved(wallet, risk.score, decision, feeBps, risk.hopDistance, risk.origin);
    }
}
