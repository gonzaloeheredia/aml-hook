// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookActivity} from "./AmlHookActivity.sol";

import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IERC20Minimal} from "../../interfaces/external/IERC20Minimal.sol";
import {ComplianceBand} from "../../libraries/ComplianceBand.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";
import {Inflow} from "../../libraries/Inflow.sol";
import {LpPolicyLib} from "../../libraries/LpPolicyLib.sol";
import {OracleQuote} from "../../libraries/OracleQuote.sol";
import {WalletSubject} from "../../libraries/WalletSubject.sol";

/// @title AmlHookLogic — swap and liquidity compliance evaluation
/// @notice Resolves the subject, reads the published COA row, gathers floor signals,
///         and delegates to `RiskPolicyLib` (swaps) or `LpPolicyLib` (LP adds). Never
///         calls the agent. Swap state mutations happen in `_endSwap`. LP never-scored
///         A/C/D run in `_evaluateNeverScoredAdd` (afterAdd, when token deltas exist).
abstract contract AmlHookLogic is AmlHookActivity {
    /// @notice Wallet is in the REVERT score band (71–100) or exceeds the unscored magnitude floor.
    error WalletBlocked(address wallet, uint8 score, string reason);
    /// @notice Wallet (or one of its multisig owners) is on the sanctions list.
    /// @dev Layer 1 only. The COA writes the mapping off-chain (live OFAC SDN match).
    ///      `beforeSwap` does not call Treasury. Distinct from `WalletBlocked` (score 71–100,
    ///      demo Wallet A exploit, not listed).
    error SanctionHit(address wallet);
    /// @notice Never-scored wallet's assessed USD meets or exceeds the unscored revert threshold.
    error UnscoredMagnitudeBlocked(address wallet, uint256 assessedUsd, uint256 threshold);
    /// @notice Never-scored wallet's pool-impact bps exceeds the threshold at a punitive fee floor.
    error UnscoredPoolImpactBlocked(address wallet, uint256 poolImpactBps, uint256 threshold);
    /// @notice Wallet's rolling daily USD (prior + this swap) meets or exceeds the revert threshold.
    error DailyAggregationBlocked(address wallet, uint256 assessedUsd, uint256 threshold);
    /// @notice USD quote for `token` is required but unavailable (`reason` is one of the QUOTE_* constants).
    error MagnitudeQuoteFailed(address token, bytes32 reason);
    /// @notice Trusted router's `msgSender()` call failed or returned `address(0)`.
    error TrustedRouterSubjectFailed(address router);
    /// @notice `syncBaseline` refused: the stored balance is newer than the oracle's last write.
    error BaselineAheadOfOracle(address wallet, address token, uint64 oracleUpdatedAt, uint256 lastWriteTs);

    /// @notice Emitted once per swap with the final compliance outcome.
    /// @param wallet      Resolved compliance subject.
    /// @param score       Published COA score at evaluation time (0–100).
    /// @param decision    ALLOW / FEE_OVERRIDE / REVERT.
    /// @param feeBps      Override fee in bps (0 on ALLOW / REVERT).
    /// @param hopDistance N-hop distance from the contamination origin as published by the COA (0 = direct / unknown).
    /// @param origin      Contamination origin wallet (`address(0)` when clean).
    event SwapObserved(
        address indexed wallet, uint8 score, HookDecision decision, uint24 feeBps, uint8 hopDistance, address origin
    );
    /// @notice Emitted when a latency-mitigation floor elevates the decision above the score band.
    /// @param wallet     Compliance subject.
    /// @param reason     One of REASON_SCORE_NEVER_WRITTEN, REASON_STALE_WITH_POOL_ACTIVITY, REASON_POOL_IMPACT.
    /// @param feeBps     Applied override fee.
    /// @param oracleScore Score at evaluation time (may be 0 if never written).
    event LatencyMitigationApplied(address indexed wallet, bytes32 reason, uint24 feeBps, uint8 oracleScore);
    /// @notice Emitted when the inflow heuristic (Mitigation D) detects a significant balance increase.
    /// @param wallet    Compliance subject.
    /// @param deltaBps  Inflow share in bps relative to current balance.
    /// @param timestamp Block timestamp at detection.
    event InflowHeuristicTriggered(address indexed wallet, uint256 deltaBps, uint256 timestamp);
    /// @notice LP subject after router `msgSender()` or the direct sender.
    event LiquiditySubjectResolved(address indexed sender, address indexed subject, bool viaTrustedRouter);
    /// @notice L1→L3 outcome on add or remove. `seized` is only meaningful on remove.
    event LiquidityObserved(
        address indexed wallet,
        uint8 score,
        HookDecision decision,
        bool seized,
        bool viaTrustedRouter
    );

    /// @dev USD quote pair for the volume token and the input token (may share an instance when equal).
    struct QuoteCtx {
        OracleQuote.Fx volume;  // FX for the specified / volume token
        OracleQuote.Fx input;   // FX for the input token (Mitigation D baseline)
        bytes32 volumeErr;      // non-zero OracleQuote error code when volume quote failed
        bytes32 inputErr;       // non-zero OracleQuote error code when input quote failed
    }

    /// @notice `LatencyMitigationApplied` reason: wallet has no score on-chain yet.
    bytes32 public constant REASON_SCORE_NEVER_WRITTEN = keccak256("SCORE_NEVER_WRITTEN");
    /// @notice `LatencyMitigationApplied` reason: score is stale and there is activity in the current window.
    bytes32 public constant REASON_STALE_WITH_POOL_ACTIVITY = keccak256("STALE_WITH_POOL_ACTIVITY");
    /// @notice `LatencyMitigationApplied` reason: pool-impact bps exceeded the configured threshold.
    bytes32 public constant REASON_POOL_IMPACT = keccak256("POOL_IMPACT");

    /// @notice `MagnitudeQuoteFailed` reason: no Chainlink feed registered for the token.
    bytes32 public constant QUOTE_NO_FEED = OracleQuote.NO_FEED;
    /// @notice `MagnitudeQuoteFailed` reason: live feed and cache both exceeded `maxPriceStaleness`.
    bytes32 public constant QUOTE_STALE_FEED = OracleQuote.STALE_FEED;
    /// @notice `MagnitudeQuoteFailed` reason: feed returned a non-positive or malformed price.
    bytes32 public constant QUOTE_BAD_PRICE = OracleQuote.BAD_PRICE;
    /// @notice `MagnitudeQuoteFailed` reason: USD window accumulator overflowed (quote-failure sentinel).
    bytes32 public constant QUOTE_WINDOW_FAILED = OracleQuote.WINDOW_FAILED;

    /// @dev Full result passed from `_beginSwap` to `_endSwap` via transient storage (SwapCache).
    struct SwapEvaluation {
        address wallet;                      // resolved compliance subject
        address token;                       // input token (Mitigation D baseline)
        HookDecision decision;               // ALLOW / FEE_OVERRIDE / REVERT
        uint24 feeBps;                       // differential fee in bps (0 on ALLOW)
        IComplianceOracle.WalletRisk risk;   // oracle snapshot at evaluation time
        bool inflowTriggered;                // true when Mitigation D detected a significant inflow
        OracleQuote.Fx volumeFx;             // FX quote cached for `_endSwap` activity recording
    }

    /// @dev Intermediate signals gathered before calling `riskPolicy.decide`.
    struct EvalSignals {
        bool isStale;               // score age exceeds `stalenessThreshold`
        uint32 operationCount;      // ops in the current activity window
        bool hasSignificantInflow;  // Mitigation D: inflow share exceeds `inflowThresholdBps`
        bool neverScored;           // oracle `updatedAt == 0`
        uint256 inflowShareBps;     // inflow fraction of current balance in bps
        uint256 assessedUsd;        // USD value assessed for magnitude floors A/B
        uint256 inflowTokenDelta;   // raw token units of the inflow (pre-USD conversion)
        uint256 inflowUsd;          // USD value of the inflow (Mitigation D)
        uint256 priorDailyUsd;      // daily rolling volume before this swap
        uint256 swapUsd;            // USD value of this swap alone (daily aggregation check)
    }

    /// @dev One memory pointer through `_evaluateCore`. Live path copies fields into `SwapEvaluation`.
    struct EvalFrame {
        HookDecision decision;
        uint24 feeBps;
        IComplianceOracle.WalletRisk risk;
        EvalSignals signals;
        QuoteCtx q;
    }

    /// @dev Resolves the compliance subject from `router` and runs the full live evaluation.
    ///      Called in `beforeSwap`; the result is stored in transient storage for `afterSwap`.
    function _beginSwap(address router, address token, address volumeToken, uint256 amount, uint256 poolImpactBps)
        internal
        returns (SwapEvaluation memory eval)
    {
        eval = _evaluateLive(
            WalletSubject.resolve(router, trustedRouters, trustedMultisigs, sanctionRegistry, multisigAggregation),
            token,
            volumeToken,
            amount,
            poolImpactBps
        );
    }

    /// @dev Records settled volume and updates the Mitigation D balance baseline.
    ///      Called in `afterSwap` after the transient cache has been consumed.
    function _endSwap(SwapEvaluation memory eval, address volumeToken, uint256 settledAmount) internal {
        _recordActivity(eval.wallet, volumeToken, settledAmount, eval.volumeFx);
        _updateKnownBalance(eval.wallet, eval.token, eval.inflowTriggered);
        _emitSwapObserved(eval.wallet, eval.decision, eval.feeBps, eval.risk);
    }

    /// @notice Off-chain preview of the compliance decision for a given wallet, token, and amount.
    /// @dev Same L1→L3 path as `beforeSwap`. Reads the published COA row; does not call the agent.
    ///      Does not record activity, update baselines, or commit FX cache.
    ///      Uses `poolImpactBps = 0` and `volumeToken = token`.
    /// @param wallet  Compliance subject to evaluate.
    /// @param token   Token being swapped (used as both input and volume token).
    /// @param amount  Native token units of the swap.
    /// @return decision ALLOW / FEE_OVERRIDE / REVERT.
    /// @return feeBps   Override fee in bps (0 when decision is ALLOW or REVERT).
    /// @return risk     Oracle snapshot used in the evaluation.
    function previewSwap(address wallet, address token, uint256 amount)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, token, token, amount, 0);
    }

    /// @notice Governor-triggered evaluation that also records activity and updates the baseline.
    /// @dev Useful for off-chain-triggered compliance checks (e.g. manual review of a wallet).
    ///      Uses `poolImpactBps = 0` and `settledAmount = 0`; no FX is committed from a zero amount.
    /// @param wallet  Compliance subject.
    /// @param token   Token to evaluate (used as both input and volume token).
    /// @param amount  Hypothetical native-unit amount for signal gathering.
    /// @return decision ALLOW / FEE_OVERRIDE / REVERT.
    /// @return feeBps   Override fee in bps.
    /// @return risk     Oracle snapshot used in the evaluation.
    function observeSwap(address wallet, address token, uint256 amount)
        external
        restricted
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        SwapEvaluation memory eval = _evaluateLive(wallet, token, token, amount, 0);
        _endSwap(eval, token, 0);
        return (eval.decision, eval.feeBps, eval.risk);
    }

    /// @notice Force-refresh the Mitigation D balance baseline for `wallet` and `token`.
    /// @dev Reverts when the stored baseline is newer than the oracle's last write and the balance
    ///      has grown since — advancing the baseline would hide a pre-score inflow from the heuristic.
    /// @param wallet Compliance subject whose baseline to refresh.
    /// @param token  ERC-20 token to snapshot; address(0) or non-contract is a no-op.
    function syncBaseline(address wallet, address token) external restricted {
        if (token != address(0) && token.code.length != 0) {
            uint256 lastWriteTs = lastKnownBalanceTimestamp[wallet][token];
            if (lastWriteTs != 0) {
                uint256 currentBalance = IERC20Minimal(token).balanceOf(wallet);
                if (currentBalance > lastKnownBalance[wallet][token]) {
                    uint64 oracleUpdatedAt = complianceOracle.getRisk(wallet).updatedAt;
                    if (uint256(oracleUpdatedAt) <= lastWriteTs) {
                        revert BaselineAheadOfOracle(wallet, token, oracleUpdatedAt, lastWriteTs);
                    }
                }
            }
        }
        _updateKnownBalance(wallet, token, false);
    }

    function _requireNotSanctioned(address wallet) internal view {
        if (sanctionRegistry.isSanctioned(wallet)) revert SanctionHit(wallet);
    }

    /// @dev Trusted router → `msgSender()`. Direct caller → `sender`. Emits `LiquiditySubjectResolved`.
    function _resolveLp(address sender) internal returns (address wallet, bool viaTrustedRouter) {
        (wallet, viaTrustedRouter) =
            WalletSubject.resolveLp(sender, trustedRouters, trustedMultisigs, sanctionRegistry, multisigAggregation);
        emit LiquiditySubjectResolved(sender, wallet, viaTrustedRouter);
    }

    /// @dev Add path: L1 always reverts. Pause does not freeze a clean mint. Score ≥ 71 reverts.
    ///      Known 31–70 → FEE_OVERRIDE (score). Never-scored → Floor A/C/D in `afterAddLiquidity`.
    function _guardAddLiquidity(address sender)
        internal
        returns (
            address wallet,
            bool viaRouter,
            bool neverScored,
            HookDecision decision,
            uint24 feeBps,
            uint8 score
        )
    {
        (wallet, viaRouter) = _resolveLp(sender);
        address hit = WalletSubject.layer1Hit(wallet, trustedMultisigs, sanctionRegistry, multisigAggregation);
        if (hit != address(0)) revert SanctionHit(hit);
        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(wallet);
        score = risk.score;
        neverScored = risk.updatedAt == 0;
        if (ComplianceBand.isIllicitScore(score)) {
            revert WalletBlocked(wallet, score, "SCORE_REVERT_BAND");
        }
        if (neverScored) {
            return (wallet, viaRouter, true, HookDecision.ALLOW, 0, score);
        }
        IRiskPolicy.DecisionInput memory in_;
        in_.score = score;
        in_.recommendedFeeBps = risk.feeBps;
        IRiskPolicy.DecisionResult memory result = LpPolicyLib.decide(in_);
        decision = result.decision;
        feeBps = result.feeBps;
        emit LiquidityObserved(wallet, score, decision, false, viaRouter);
    }

    /// @dev Never-scored add: same A/C/D + pool-impact tree as a never-scored swap (`LpPolicyLib` → `RiskPolicyLib`).
    function _evaluateNeverScoredAdd(
        address wallet,
        bool viaRouter,
        address token0,
        address token1,
        uint256 amt0,
        uint256 amt1,
        uint256 poolImpactBps
    ) internal returns (HookDecision decision, uint24 feeBps) {
        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(wallet);
        EvalFrame memory frame;
        frame.risk = risk;
        frame.signals.neverScored = true;
        frame.signals.priorDailyUsd = _usdInLpDailyWindow(wallet);
        if (frame.signals.priorDailyUsd == type(uint256).max) {
            revert MagnitudeQuoteFailed(token0, QUOTE_WINDOW_FAILED);
        }

        (frame.q.volume, frame.q.volumeErr) =
            OracleQuote.resolve(priceFeeds, lastFx, priceStalenessThreshold, MAX_PRICE_STALENESS, token0);
        OracleQuote.Fx memory fx1;
        bytes32 err1;
        if (token1 != token0) {
            (fx1, err1) =
                OracleQuote.resolve(priceFeeds, lastFx, priceStalenessThreshold, MAX_PRICE_STALENESS, token1);
        } else {
            fx1 = frame.q.volume;
            err1 = frame.q.volumeErr;
        }
        if (amt0 > 0) _requireFx(token0, frame.q.volume, frame.q.volumeErr);
        if (amt1 > 0) _requireFx(token1, fx1, err1);
        uint256 usd0 = amt0 == 0 ? 0 : OracleQuote.toUsd(frame.q.volume, amt0);
        uint256 usd1 = amt1 == 0 ? 0 : OracleQuote.toUsd(fx1, amt1);
        frame.signals.assessedUsd = usd0 + usd1;
        frame.signals.swapUsd = frame.signals.assessedUsd;
        frame.signals.inflowUsd = _lpInflowUsd(wallet, token0, token1, risk.updatedAt, frame.q.volume, fx1);

        IRiskPolicy.DecisionResult memory result = LpPolicyLib.decide(_toInput(frame, poolImpactBps));
        _revertBlocked(frame, wallet, poolImpactBps, result);
        _commitQuotes(token0, token0, frame.q);
        if (token1 != token0 && fx1.price != 0) {
            OracleQuote.commit(lastFx, token1, fx1);
            _emitPriceFallback(token1, fx1);
        }
        decision = result.decision;
        feeBps = result.feeBps;
        emit LiquidityObserved(wallet, risk.score, decision, false, viaRouter);
        _recordLpDailyUsd(wallet, frame.signals.swapUsd);
    }

    /// @dev Mitigation D analog: max inbound USD of the two tokens being deposited (same `Inflow` as swaps).
    function _lpInflowUsd(
        address wallet,
        address token0,
        address token1,
        uint64 updatedAt,
        OracleQuote.Fx memory fx0,
        OracleQuote.Fx memory fx1
    ) private view returns (uint256 inflowUsd) {
        inflowUsd = _oneTokenInflowUsd(wallet, token0, updatedAt, fx0);
        uint256 other = _oneTokenInflowUsd(wallet, token1, updatedAt, fx1);
        if (other > inflowUsd) inflowUsd = other;
    }

    function _oneTokenInflowUsd(address wallet, address token, uint64 updatedAt, OracleQuote.Fx memory fx)
        private
        view
        returns (uint256)
    {
        (, , uint256 delta) =
            Inflow.signal(wallet, token, updatedAt, lastKnownBalance, lastKnownBalanceTimestamp, inflowThresholdBps);
        if (delta == 0 || fx.price == 0) return 0;
        return OracleQuote.toUsd(fx, delta);
    }

    /// @dev Remove path: no pause. L1 or score ≥ 71 → seize (do not revert). Clean LP exits even while paused.
    function _evaluateRemoveLiquidity(address sender)
        internal
        returns (address wallet, bool seize, uint8 score, bool viaRouter)
    {
        (wallet, viaRouter) = _resolveLp(sender);
        address hit = WalletSubject.layer1Hit(wallet, trustedMultisigs, sanctionRegistry, multisigAggregation);
        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(wallet);
        score = risk.score;
        seize = hit != address(0) || ComplianceBand.isIllicitScore(score);
        emit LiquidityObserved(
            wallet, score, seize ? HookDecision.REVERT : HookDecision.ALLOW, seize, viaRouter
        );
    }

    function _evaluate(address wallet, address token, address volumeToken, uint256 amount, uint256 poolImpactBps)
        internal
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        EvalFrame memory frame = _evaluateCore(wallet, token, volumeToken, amount, poolImpactBps);
        return (frame.decision, frame.feeBps, frame.risk);
    }

    function _evaluateLive(address wallet, address token, address volumeToken, uint256 amount, uint256 poolImpactBps)
        internal
        returns (SwapEvaluation memory eval)
    {
        EvalFrame memory frame = _evaluateCore(wallet, token, volumeToken, amount, poolImpactBps);
        _hydrate(eval, frame, wallet, token);
        _commitQuotes(token, volumeToken, frame.q);
        _emitMitigations(frame, wallet, poolImpactBps);
    }

    /// @dev Reads `ComplianceOracle` only. The agent is never invoked on this path.
    function _evaluateCore(
        address wallet,
        address token,
        address volumeToken,
        uint256 amount,
        uint256 poolImpactBps
    ) private view returns (EvalFrame memory frame) {
        _requireNotPaused();
        _requireNotSanctioned(wallet);
        frame.risk = complianceOracle.getRisk(wallet);
        _gather(frame, wallet, token, volumeToken, amount);
        IRiskPolicy.DecisionResult memory result = riskPolicy.decide(_toInput(frame, poolImpactBps));
        _revertBlocked(frame, wallet, poolImpactBps, result);
        frame.decision = result.decision;
        frame.feeBps = result.feeBps;
    }

    function _hydrate(SwapEvaluation memory eval, EvalFrame memory frame, address wallet, address token)
        private
        pure
    {
        eval.wallet = wallet;
        eval.token = token;
        eval.decision = frame.decision;
        eval.feeBps = frame.feeBps;
        eval.risk = frame.risk;
        eval.inflowTriggered = frame.signals.hasSignificantInflow;
        eval.volumeFx = frame.q.volume;
    }

    function _commitQuotes(address token, address volumeToken, QuoteCtx memory q) private {
        OracleQuote.commit(lastFx, volumeToken, q.volume);
        if (token != volumeToken) OracleQuote.commit(lastFx, token, q.input);
        _emitPriceFallback(volumeToken, q.volume);
        if (token != volumeToken && q.input.price != 0) _emitPriceFallback(token, q.input);
    }

    function _gather(EvalFrame memory frame, address wallet, address token, address volumeToken, uint256 amount)
        private
        view
    {
        _gatherSignals(frame, wallet, token, volumeToken);
        _resolveQuotes(token, volumeToken, amount, frame.signals, frame.q);
        _fillUsd(wallet, token, volumeToken, amount, frame.signals, frame.q);
    }

    function _gatherSignals(EvalFrame memory frame, address wallet, address token, address volumeToken)
        private
        view
    {
        EvalSignals memory signals = frame.signals;
        uint64 updatedAt = frame.risk.updatedAt;
        signals.operationCount = _opsInCurrentWindow(wallet);
        signals.isStale = updatedAt == 0 || block.timestamp > uint256(updatedAt) + stalenessThreshold;
        (signals.hasSignificantInflow, signals.inflowShareBps, signals.inflowTokenDelta) =
            Inflow.signal(wallet, token, updatedAt, lastKnownBalance, lastKnownBalanceTimestamp, inflowThresholdBps);
        signals.neverScored = updatedAt == 0;
        signals.priorDailyUsd = _usdInDailyWindow(wallet);
        if (signals.priorDailyUsd == type(uint256).max) {
            revert MagnitudeQuoteFailed(volumeToken, QUOTE_WINDOW_FAILED);
        }
    }

    function _resolveQuotes(
        address token,
        address volumeToken,
        uint256 amount,
        EvalSignals memory signals,
        QuoteCtx memory q
    ) private view {
        bool needVolume = amount > 0 || signals.neverScored
            || (signals.isStale && signals.operationCount > 0) || signals.priorDailyUsd > 0
            || (signals.inflowTokenDelta > 0 && token == volumeToken);
        if (needVolume) {
            (q.volume, q.volumeErr) =
                OracleQuote.resolve(priceFeeds, lastFx, priceStalenessThreshold, MAX_PRICE_STALENESS, volumeToken);
        }
        if (signals.inflowTokenDelta > 0) {
            if (token == volumeToken) {
                q.input = q.volume;
                q.inputErr = q.volumeErr;
            } else {
                (q.input, q.inputErr) =
                    OracleQuote.resolve(priceFeeds, lastFx, priceStalenessThreshold, MAX_PRICE_STALENESS, token);
            }
        }
    }

    function _fillUsd(
        address wallet,
        address token,
        address volumeToken,
        uint256 amount,
        EvalSignals memory signals,
        QuoteCtx memory q
    ) private view {
        if (signals.neverScored) {
            _fillNeverScored(token, volumeToken, amount, signals, q);
            return;
        }
        if (signals.inflowTokenDelta > 0) _fillInflowShare(wallet, token, signals, q);
        if (signals.isStale && signals.operationCount > 0) {
            _fillStaleWindow(wallet, volumeToken, amount, signals, q);
        }
        if (signals.priorDailyUsd > 0 && amount > 0) _fillDailySwapUsd(volumeToken, amount, signals, q);
    }

    function _fillNeverScored(
        address token,
        address volumeToken,
        uint256 amount,
        EvalSignals memory signals,
        QuoteCtx memory q
    ) private pure {
        _requireFx(volumeToken, q.volume, q.volumeErr);
        signals.assessedUsd = OracleQuote.toUsd(q.volume, amount);
        signals.swapUsd = signals.assessedUsd;
        if (signals.inflowTokenDelta > 0) {
            _requireFx(token, q.input, q.inputErr);
            signals.inflowUsd = OracleQuote.toUsd(q.input, signals.inflowTokenDelta);
        }
    }

    function _fillInflowShare(address wallet, address token, EvalSignals memory signals, QuoteCtx memory q)
        private
        view
    {
        _requireFx(token, q.input, q.inputErr);
        signals.inflowUsd = OracleQuote.toUsd(q.input, signals.inflowTokenDelta);
        uint256 currentBalance = IERC20Minimal(token).balanceOf(wallet);
        uint256 currentBalanceUsd = OracleQuote.toUsd(q.input, currentBalance);
        if (currentBalanceUsd > 0) {
            signals.inflowShareBps = (signals.inflowUsd * 10_000) / currentBalanceUsd;
            signals.hasSignificantInflow = signals.inflowShareBps > inflowThresholdBps;
        } else {
            signals.hasSignificantInflow = false;
        }
    }

    function _fillStaleWindow(
        address wallet,
        address volumeToken,
        uint256 amount,
        EvalSignals memory signals,
        QuoteCtx memory q
    ) private view {
        uint256 windowUsd = _usdInCurrentWindow(wallet);
        if (windowUsd == type(uint256).max) revert MagnitudeQuoteFailed(volumeToken, QUOTE_WINDOW_FAILED);
        _requireFx(volumeToken, q.volume, q.volumeErr);
        signals.assessedUsd = windowUsd + OracleQuote.toUsd(q.volume, amount);
    }

    function _fillDailySwapUsd(address volumeToken, uint256 amount, EvalSignals memory signals, QuoteCtx memory q)
        private
        pure
    {
        _requireFx(volumeToken, q.volume, q.volumeErr);
        signals.swapUsd = OracleQuote.toUsd(q.volume, amount);
    }

    function _requireFx(address token, OracleQuote.Fx memory fx, bytes32 err) private pure {
        if (err != bytes32(0) || fx.price == 0) {
            revert MagnitudeQuoteFailed(token, err == bytes32(0) ? QUOTE_NO_FEED : err);
        }
    }

    function _emitPriceFallback(address token, OracleQuote.Fx memory fx) private {
        if (fx.price == 0 || !fx.stale) return;
        emit PriceFallbackUsed(token, fx.price, fx.quotedAt, fx.fromCache, fx.stale);
    }

    function _toInput(EvalFrame memory frame, uint256 poolImpactBps)
        private
        view
        returns (IRiskPolicy.DecisionInput memory i)
    {
        _copyRiskSignals(i, frame);
        _copyThresholds(i, poolImpactBps);
    }

    function _copyRiskSignals(IRiskPolicy.DecisionInput memory i, EvalFrame memory frame) private pure {
        i.score = frame.risk.score;
        i.recommendedFeeBps = frame.risk.feeBps;
        i.isStale = frame.signals.isStale;
        i.operationCount = frame.signals.operationCount;
        i.neverScored = frame.signals.neverScored;
        i.assessedUsd = frame.signals.assessedUsd;
        i.inflowUsd = frame.signals.inflowUsd;
        i.priorDailyUsd = frame.signals.priorDailyUsd;
        i.swapUsd = frame.signals.swapUsd;
    }

    function _copyThresholds(IRiskPolicy.DecisionInput memory i, uint256 poolImpactBps) private view {
        i.unscoredFeeThreshold = unscoredFeeThreshold;
        i.unscoredRevertThreshold = unscoredRevertThreshold;
        i.proportionalFeeBps = proportionalFeeBps;
        i.punitiveFeeBps = punitiveFeeBps;
        i.poolImpactBps = poolImpactBps;
        i.poolImpactThresholdBps = poolImpactThresholdBps;
    }

    function _revertBlocked(
        EvalFrame memory frame,
        address wallet,
        uint256 poolImpactBps,
        IRiskPolicy.DecisionResult memory result
    ) private view {
        if (result.decision != HookDecision.REVERT) return;
        if (result.revertKind == IRiskPolicy.RevertKind.UnscoredMagnitude) {
            revert UnscoredMagnitudeBlocked(wallet, frame.signals.assessedUsd, unscoredRevertThreshold);
        }
        if (result.revertKind == IRiskPolicy.RevertKind.UnscoredPoolImpact) {
            revert UnscoredPoolImpactBlocked(wallet, poolImpactBps, poolImpactThresholdBps);
        }
        if (result.revertKind == IRiskPolicy.RevertKind.DailyAggregation) {
            revert DailyAggregationBlocked(
                wallet, frame.signals.priorDailyUsd + frame.signals.swapUsd, unscoredRevertThreshold
            );
        }
        _revertScoreBand(wallet, frame.risk.score);
    }

    function _revertScoreBand(address wallet, uint8 score) private pure {
        revert WalletBlocked(wallet, score, "SCORE_REVERT_BAND");
    }

    function _emitMitigations(EvalFrame memory frame, address wallet, uint256 poolImpactBps) private {
        EvalSignals memory signals = frame.signals;
        if (signals.hasSignificantInflow || (unscoredFeeThreshold != 0 && signals.inflowUsd >= unscoredFeeThreshold)) {
            emit InflowHeuristicTriggered(wallet, signals.inflowShareBps, block.timestamp);
        }
        if (frame.risk.updatedAt == 0 && frame.decision == HookDecision.FEE_OVERRIDE) {
            emit LatencyMitigationApplied(
                wallet, _poolImpactReason(poolImpactBps, REASON_SCORE_NEVER_WRITTEN), frame.feeBps, frame.risk.score
            );
        }
        if (
            frame.risk.score <= 30 && signals.isStale && signals.operationCount > 0
                && frame.decision == HookDecision.FEE_OVERRIDE
        ) {
            bytes32 reason = _poolImpactReason(poolImpactBps, REASON_STALE_WITH_POOL_ACTIVITY);
            if (reason == REASON_POOL_IMPACT || (unscoredFeeThreshold != 0 && signals.assessedUsd >= unscoredFeeThreshold))
            {
                emit LatencyMitigationApplied(wallet, reason, frame.feeBps, frame.risk.score);
            }
        }
    }

    function _poolImpactReason(uint256 poolImpactBps, bytes32 fallbackReason) private view returns (bytes32) {
        if (poolImpactThresholdBps != 0 && poolImpactBps > poolImpactThresholdBps) return REASON_POOL_IMPACT;
        return fallbackReason;
    }

    function _emitSwapObserved(
        address wallet,
        HookDecision decision,
        uint24 feeBps,
        IComplianceOracle.WalletRisk memory risk
    ) internal {
        emit SwapObserved(wallet, risk.score, decision, feeBps, risk.hopDistance, risk.origin);
    }
}
