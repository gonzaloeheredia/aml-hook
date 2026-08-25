// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookActivity} from "./AmlHookActivity.sol";

import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IERC20Minimal} from "../../interfaces/external/IERC20Minimal.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";
import {Inflow} from "../../libraries/Inflow.sol";
import {OracleQuote} from "../../libraries/OracleQuote.sol";
import {RiskPolicyLib} from "../../libraries/RiskPolicyLib.sol";
import {WalletSubject} from "../../libraries/WalletSubject.sol";

/// @title beforeSwap / afterSwap compliance: resolve subject, gather signals, RiskPolicyLib.decide.
abstract contract AmlHookLogic is AmlHookActivity {
    error WalletBlocked(address wallet, uint8 score, string reason);
    error SanctionHit(address wallet);
    error UnscoredMagnitudeBlocked(address wallet, uint256 assessedUsd, uint256 threshold);
    error UnscoredPoolImpactBlocked(address wallet, uint256 poolImpactBps, uint256 threshold);
    error DailyAggregationBlocked(address wallet, uint256 assessedUsd, uint256 threshold);
    error MagnitudeQuoteFailed(address token, bytes32 reason);
    error TrustedRouterSubjectFailed(address router);
    error BaselineAheadOfOracle(address wallet, address token, uint64 oracleUpdatedAt, uint256 lastWriteTs);

    event SwapObserved(
        address indexed wallet, uint8 score, HookDecision decision, uint24 feeBps, uint8 hopDistance, address origin
    );
    event LatencyMitigationApplied(address indexed wallet, bytes32 reason, uint24 feeBps, uint8 oracleScore);
    event InflowHeuristicTriggered(address indexed wallet, uint256 deltaBps, uint256 timestamp);

    struct QuoteCtx {
        OracleQuote.Fx volume;
        OracleQuote.Fx input;
        bytes32 volumeErr;
        bytes32 inputErr;
    }

    bytes32 public constant REASON_SCORE_NEVER_WRITTEN = keccak256("SCORE_NEVER_WRITTEN");
    bytes32 public constant REASON_STALE_WITH_POOL_ACTIVITY = keccak256("STALE_WITH_POOL_ACTIVITY");
    bytes32 public constant REASON_POOL_IMPACT = keccak256("POOL_IMPACT");
    bytes32 public constant QUOTE_NO_FEED = OracleQuote.NO_FEED;
    bytes32 public constant QUOTE_STALE_FEED = OracleQuote.STALE_FEED;
    bytes32 public constant QUOTE_BAD_PRICE = OracleQuote.BAD_PRICE;
    bytes32 public constant QUOTE_WINDOW_FAILED = OracleQuote.WINDOW_FAILED;

    struct SwapEvaluation {
        address wallet;
        address token;
        HookDecision decision;
        uint24 feeBps;
        IComplianceOracle.WalletRisk risk;
        bool inflowTriggered;
        OracleQuote.Fx volumeFx;
    }

    struct EvalSignals {
        bool isStale;
        uint32 operationCount;
        bool hasSignificantInflow;
        bool neverScored;
        uint256 inflowShareBps;
        uint256 assessedUsd;
        uint256 inflowTokenDelta;
        uint256 inflowUsd;
        uint256 priorDailyUsd;
        uint256 swapUsd;
    }

    /// @dev One memory pointer through `_evaluateCore`. Live path copies into `SwapEvaluation`.
    struct EvalFrame {
        HookDecision decision;
        uint24 feeBps;
        IComplianceOracle.WalletRisk risk;
        EvalSignals signals;
        QuoteCtx q;
    }

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

    function _endSwap(SwapEvaluation memory eval, address volumeToken, uint256 settledAmount) internal {
        _recordActivity(eval.wallet, volumeToken, settledAmount, eval.volumeFx);
        _updateKnownBalance(eval.wallet, eval.token, eval.inflowTriggered);
        _emitSwapObserved(eval.wallet, eval.decision, eval.feeBps, eval.risk);
    }

    function previewSwap(address wallet, address token, uint256 amount)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet, token, token, amount, 0);
    }

    function observeSwap(address wallet, address token, uint256 amount)
        external
        restricted
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        SwapEvaluation memory eval = _evaluateLive(wallet, token, token, amount, 0);
        _endSwap(eval, token, 0);
        return (eval.decision, eval.feeBps, eval.risk);
    }

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
        eval.wallet = wallet;
        eval.token = token;
        eval.decision = frame.decision;
        eval.feeBps = frame.feeBps;
        eval.risk = frame.risk;
        eval.inflowTriggered = frame.signals.hasSignificantInflow;
        eval.volumeFx = frame.q.volume;
        OracleQuote.commit(lastFx, volumeToken, frame.q.volume);
        if (token != volumeToken) OracleQuote.commit(lastFx, token, frame.q.input);
        _emitPriceFallback(volumeToken, frame.q.volume);
        if (token != volumeToken && frame.q.input.price != 0) _emitPriceFallback(token, frame.q.input);
        _emitMitigations(wallet, frame.risk, frame.signals, poolImpactBps, frame.decision, frame.feeBps);
    }

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
        (frame.signals, frame.q) = _gather(wallet, token, volumeToken, amount, frame.risk);
        IRiskPolicy.DecisionResult memory result =
            RiskPolicyLib.decide(_toInput(frame.risk, frame.signals, poolImpactBps));
        _revertBlocked(wallet, frame.risk, frame.signals, poolImpactBps, result);
        frame.decision = result.decision;
        frame.feeBps = result.feeBps;
    }

    function _gather(
        address wallet,
        address token,
        address volumeToken,
        uint256 amount,
        IComplianceOracle.WalletRisk memory risk
    ) private view returns (EvalSignals memory signals, QuoteCtx memory q) {
        signals.operationCount = _opsInCurrentWindow(wallet);
        signals.isStale = risk.updatedAt == 0 || block.timestamp > uint256(risk.updatedAt) + stalenessThreshold;
        (signals.hasSignificantInflow, signals.inflowShareBps, signals.inflowTokenDelta) = Inflow.signal(
            wallet, token, risk.updatedAt, lastKnownBalance, lastKnownBalanceTimestamp, inflowThresholdBps
        );
        signals.neverScored = risk.updatedAt == 0;
        signals.priorDailyUsd = _usdInDailyWindow(wallet);
        if (signals.priorDailyUsd == type(uint256).max) {
            revert MagnitudeQuoteFailed(volumeToken, QUOTE_WINDOW_FAILED);
        }
        _resolveQuotes(token, volumeToken, amount, signals, q);
        _fillUsd(wallet, token, volumeToken, amount, signals, q);
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
            _requireFx(volumeToken, q.volume, q.volumeErr);
            signals.assessedUsd = OracleQuote.toUsd(q.volume, amount);
            signals.swapUsd = signals.assessedUsd;
            if (signals.inflowTokenDelta > 0) {
                _requireFx(token, q.input, q.inputErr);
                signals.inflowUsd = OracleQuote.toUsd(q.input, signals.inflowTokenDelta);
            }
            return;
        }
        if (signals.inflowTokenDelta > 0) {
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
        if (signals.isStale && signals.operationCount > 0) {
            uint256 windowUsd = _usdInCurrentWindow(wallet);
            if (windowUsd == type(uint256).max) revert MagnitudeQuoteFailed(volumeToken, QUOTE_WINDOW_FAILED);
            _requireFx(volumeToken, q.volume, q.volumeErr);
            signals.assessedUsd = windowUsd + OracleQuote.toUsd(q.volume, amount);
        }
        if (signals.priorDailyUsd > 0 && amount > 0) {
            _requireFx(volumeToken, q.volume, q.volumeErr);
            signals.swapUsd = OracleQuote.toUsd(q.volume, amount);
        }
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

    function _toInput(IComplianceOracle.WalletRisk memory risk, EvalSignals memory signals, uint256 poolImpactBps)
        private
        view
        returns (IRiskPolicy.DecisionInput memory i)
    {
        i.score = risk.score;
        i.recommendedFeeBps = risk.feeBps;
        i.isStale = signals.isStale;
        i.operationCount = signals.operationCount;
        i.neverScored = signals.neverScored;
        i.assessedUsd = signals.assessedUsd;
        i.inflowUsd = signals.inflowUsd;
        i.unscoredFeeThreshold = unscoredFeeThreshold;
        i.unscoredRevertThreshold = unscoredRevertThreshold;
        i.proportionalFeeBps = proportionalFeeBps;
        i.punitiveFeeBps = punitiveFeeBps;
        i.poolImpactBps = poolImpactBps;
        i.poolImpactThresholdBps = poolImpactThresholdBps;
        i.priorDailyUsd = signals.priorDailyUsd;
        i.swapUsd = signals.swapUsd;
    }

    function _revertBlocked(
        address wallet,
        IComplianceOracle.WalletRisk memory risk,
        EvalSignals memory signals,
        uint256 poolImpactBps,
        IRiskPolicy.DecisionResult memory result
    ) private view {
        if (result.decision != HookDecision.REVERT) return;
        if (result.revertKind == IRiskPolicy.RevertKind.UnscoredMagnitude) {
            revert UnscoredMagnitudeBlocked(wallet, signals.assessedUsd, unscoredRevertThreshold);
        }
        if (result.revertKind == IRiskPolicy.RevertKind.UnscoredPoolImpact) {
            revert UnscoredPoolImpactBlocked(wallet, poolImpactBps, poolImpactThresholdBps);
        }
        if (result.revertKind == IRiskPolicy.RevertKind.DailyAggregation) {
            revert DailyAggregationBlocked(wallet, signals.priorDailyUsd + signals.swapUsd, unscoredRevertThreshold);
        }
        _revertScoreBand(wallet, risk.score);
    }

    function _revertScoreBand(address wallet, uint8 score) private pure {
        revert WalletBlocked(wallet, score, "SCORE_REVERT_BAND");
    }

    function _emitMitigations(
        address wallet,
        IComplianceOracle.WalletRisk memory risk,
        EvalSignals memory signals,
        uint256 poolImpactBps,
        HookDecision decision,
        uint24 feeBps
    ) private {
        if (signals.hasSignificantInflow || (unscoredFeeThreshold != 0 && signals.inflowUsd >= unscoredFeeThreshold)) {
            emit InflowHeuristicTriggered(wallet, signals.inflowShareBps, block.timestamp);
        }
        if (risk.updatedAt == 0 && decision == HookDecision.FEE_OVERRIDE) {
            bytes32 reason = (poolImpactThresholdBps != 0 && poolImpactBps > poolImpactThresholdBps)
                ? REASON_POOL_IMPACT
                : REASON_SCORE_NEVER_WRITTEN;
            emit LatencyMitigationApplied(wallet, reason, feeBps, risk.score);
        }
        if (
            risk.score <= 30 && signals.isStale && signals.operationCount > 0 && decision == HookDecision.FEE_OVERRIDE
        ) {
            bytes32 reason = (poolImpactThresholdBps != 0 && poolImpactBps > poolImpactThresholdBps)
                ? REASON_POOL_IMPACT
                : REASON_STALE_WITH_POOL_ACTIVITY;
            if (reason == REASON_POOL_IMPACT || (unscoredFeeThreshold != 0 && signals.assessedUsd >= unscoredFeeThreshold))
            {
                emit LatencyMitigationApplied(wallet, reason, feeBps, risk.score);
            }
        }
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
