// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookActivity} from "./AmlHookActivity.sol";

import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IERC20Minimal} from "../../interfaces/external/IERC20Minimal.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";
import {Inflow} from "../../libraries/Inflow.sol";
import {OracleQuote} from "../../libraries/OracleQuote.sol";
import {DecisionPack} from "../../libraries/DecisionPack.sol";
import {WalletSubject} from "../../libraries/WalletSubject.sol";

/// @title beforeSwap / afterSwap compliance: resolve subject, gather signals, call RiskPolicy.
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

    function _beginSwap(address router, address token, address volumeToken, uint256 amount, uint256 poolImpactBps)
        internal
        returns (SwapEvaluation memory eval)
    {
        eval.wallet = WalletSubject.resolve(
            router, trustedRouters, trustedMultisigs, sanctionRegistry, multisigAggregation
        );
        eval.token = token;
        (eval.decision, eval.feeBps, eval.risk, eval.inflowTriggered) =
            _evaluateLive(eval.wallet, token, volumeToken, amount, poolImpactBps);
    }

    function _endSwap(SwapEvaluation memory eval, address volumeToken, uint256 settledAmount) internal {
        _recordActivity(eval.wallet, volumeToken, settledAmount);
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
        SwapEvaluation memory eval;
        eval.wallet = wallet;
        eval.token = token;
        (eval.decision, eval.feeBps, eval.risk, eval.inflowTriggered) =
            _evaluateLive(wallet, token, token, amount, 0);
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
        (decision, feeBps, risk,) = _evaluateCore(wallet, token, volumeToken, amount, poolImpactBps);
    }

    function _evaluateLive(address wallet, address token, address volumeToken, uint256 amount, uint256 poolImpactBps)
        internal
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            bool inflowTriggered
        )
    {
        EvalSignals memory signals;
        (decision, feeBps, risk, signals) = _evaluateCore(wallet, token, volumeToken, amount, poolImpactBps);
        inflowTriggered = signals.hasSignificantInflow;
        _emitMitigations(wallet, risk, signals, poolImpactBps, decision, feeBps);
    }

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
        _requireNotPaused();
        _requireNotSanctioned(wallet);
        risk = complianceOracle.getRisk(wallet);
        signals = _gather(wallet, token, volumeToken, amount, risk);
        IRiskPolicy.DecisionResult memory result = _callPolicy(_toInput(risk, signals, poolImpactBps));
        _revertBlocked(wallet, risk, signals, poolImpactBps, result);
        return (result.decision, result.feeBps, risk, signals);
    }

    function _gather(
        address wallet,
        address token,
        address volumeToken,
        uint256 amount,
        IComplianceOracle.WalletRisk memory risk
    ) private view returns (EvalSignals memory signals) {
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
        _fillUsd(wallet, token, volumeToken, amount, signals);
    }

    function _fillUsd(
        address wallet,
        address token,
        address volumeToken,
        uint256 amount,
        EvalSignals memory signals
    ) private view {
        if (signals.neverScored) {
            (signals.assessedUsd,) = _requireUsdQuote(volumeToken, amount, 0);
            signals.swapUsd = signals.assessedUsd;
            if (signals.inflowTokenDelta > 0) {
                (signals.inflowUsd,) = _requireUsdQuote(token, signals.inflowTokenDelta, 0);
            }
            return;
        }
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
        if (signals.priorDailyUsd > 0 && amount > 0) {
            (signals.swapUsd,) = _requireUsdQuote(volumeToken, amount, 0);
        }
    }

    function _toInput(IComplianceOracle.WalletRisk memory risk, EvalSignals memory signals, uint256 poolImpactBps)
        private
        view
        returns (IRiskPolicy.DecisionInput memory i)
    {
        i = _scoreInput(risk, signals);
        _fillFloors(i, signals, poolImpactBps);
    }

    function _scoreInput(IComplianceOracle.WalletRisk memory risk, EvalSignals memory signals)
        private
        pure
        returns (IRiskPolicy.DecisionInput memory i)
    {
        i.score = risk.score;
        i.recommendedFeeBps = risk.feeBps;
        i.isStale = signals.isStale;
        i.operationCount = signals.operationCount;
        i.neverScored = signals.neverScored;
    }

    function _fillFloors(
        IRiskPolicy.DecisionInput memory i,
        EvalSignals memory signals,
        uint256 poolImpactBps
    ) private view {
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

    function _callPolicy(IRiskPolicy.DecisionInput memory input)
        private
        view
        returns (IRiskPolicy.DecisionResult memory)
    {
        return _callPacked(
            DecisionPack.pack(input),
            input.assessedUsd,
            input.inflowUsd,
            input.unscoredFeeThreshold,
            input.unscoredRevertThreshold,
            input.poolImpactBps,
            input.poolImpactThresholdBps,
            input.priorDailyUsd,
            input.swapUsd
        );
    }

    function _callPacked(
        uint256 packed,
        uint256 assessedUsd,
        uint256 inflowUsd,
        uint256 unscoredFeeThreshold,
        uint256 unscoredRevertThreshold,
        uint256 poolImpactBps,
        uint256 poolImpactThresholdBps,
        uint256 priorDailyUsd,
        uint256 swapUsd
    ) private view returns (IRiskPolicy.DecisionResult memory) {
        return riskPolicy.decidePacked(
            packed,
            assessedUsd,
            inflowUsd,
            unscoredFeeThreshold,
            unscoredRevertThreshold,
            poolImpactBps,
            poolImpactThresholdBps,
            priorDailyUsd,
            swapUsd
        );
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

    function _requireUsdQuote(address token, uint256 amount, uint256 windowUsd)
        private
        view
        returns (uint256 totalUsd, bytes32 quoteError)
    {
        if (windowUsd == type(uint256).max) revert MagnitudeQuoteFailed(token, QUOTE_WINDOW_FAILED);
        (uint256 usd, bytes32 err) = OracleQuote.tryQuote(priceFeeds, priceStalenessThreshold, token, amount);
        if (err != bytes32(0)) revert MagnitudeQuoteFailed(token, err);
        return (windowUsd + usd, bytes32(0));
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
