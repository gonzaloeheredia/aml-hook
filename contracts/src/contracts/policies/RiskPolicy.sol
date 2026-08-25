// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";

/// @title Layer 3 — ternary decision + latency floors A–D. Pure; no storage, no quotes.
contract RiskPolicy is IRiskPolicy {
    uint24 public constant STANDARD_FEE_BPS = FeeBps.STANDARD;
    uint24 public constant PUNITIVE_FEE_BPS = FeeBps.PUNITIVE;
    uint24 public constant PROPORTIONAL_FEE_BPS = FeeBps.PROPORTIONAL;
    uint24 public constant LATENCY_FEE_BPS = FeeBps.LATENCY;
    uint24 public constant MAX_OVERRIDE_FEE_BPS = FeeBps.MAX_OVERRIDE;

    /// @inheritdoc IRiskPolicy
    function decide(DecisionInput calldata in_) external pure returns (DecisionResult memory r) {
        if (in_.score >= 71) {
            return DecisionResult(HookDecision.REVERT, 0, RevertKind.ScoreBand);
        }

        if (in_.neverScored) {
            r = _neverScored(in_);
        } else if (in_.score >= 31) {
            r.decision = HookDecision.FEE_OVERRIDE;
            r.feeBps = _resolveOverrideFee(in_);
            r = _applyStalePoolImpact(in_, r);
        } else {
            r = _allowBand(in_);
            r = _applyStalePoolImpact(in_, r);
        }

        if (r.decision != HookDecision.REVERT && _dailyBlocked(in_)) {
            return DecisionResult(HookDecision.REVERT, 0, RevertKind.DailyAggregation);
        }
    }

    function _neverScored(DecisionInput calldata in_) private pure returns (DecisionResult memory r) {
        if (in_.unscoredRevertThreshold != 0 && in_.assessedUsd >= in_.unscoredRevertThreshold) {
            return DecisionResult(HookDecision.REVERT, 0, RevertKind.UnscoredMagnitude);
        }
        uint24 aFee = (in_.unscoredFeeThreshold != 0 && in_.assessedUsd < in_.unscoredFeeThreshold)
            ? in_.proportionalFeeBps
            : in_.punitiveFeeBps;
        uint24 bagFee = _publishedUsdBand(
            in_.inflowUsd, in_.unscoredFeeThreshold, in_.unscoredRevertThreshold, in_.proportionalFeeBps, in_.punitiveFeeBps
        );
        r.decision = HookDecision.FEE_OVERRIDE;
        r.feeBps = aFee > bagFee ? aFee : bagFee;

        if (in_.poolImpactThresholdBps != 0 && in_.poolImpactBps > in_.poolImpactThresholdBps) {
            if (r.feeBps >= in_.punitiveFeeBps) {
                return DecisionResult(HookDecision.REVERT, 0, RevertKind.UnscoredPoolImpact);
            }
            r.feeBps = in_.punitiveFeeBps;
        }
    }

    function _allowBand(DecisionInput calldata in_) private pure returns (DecisionResult memory r) {
        uint24 bFee;
        if (in_.isStale) {
            bFee = in_.operationCount > 0
                ? _publishedUsdBand(
                    in_.assessedUsd,
                    in_.unscoredFeeThreshold,
                    in_.unscoredRevertThreshold,
                    in_.proportionalFeeBps,
                    in_.punitiveFeeBps
                )
                : in_.proportionalFeeBps;
        }
        uint24 dFee = _publishedUsdBand(
            in_.inflowUsd, in_.unscoredFeeThreshold, in_.unscoredRevertThreshold, in_.proportionalFeeBps, in_.punitiveFeeBps
        );
        r.feeBps = bFee > dFee ? bFee : dFee;
        if (r.feeBps > 0) r.decision = HookDecision.FEE_OVERRIDE;
    }

    /// @dev Floor B extra: stale + pool drain hardens pass→mid, mid→high. Never REVERT. No ops gate (H-01).
    function _applyStalePoolImpact(DecisionInput calldata in_, DecisionResult memory r)
        private
        pure
        returns (DecisionResult memory)
    {
        if (!in_.isStale || in_.poolImpactThresholdBps == 0 || in_.poolImpactBps <= in_.poolImpactThresholdBps) {
            return r;
        }
        if (r.decision == HookDecision.ALLOW) {
            r.decision = HookDecision.FEE_OVERRIDE;
            r.feeBps = in_.proportionalFeeBps;
        } else if (r.decision == HookDecision.FEE_OVERRIDE && r.feeBps < in_.punitiveFeeBps) {
            r.feeBps = in_.punitiveFeeBps;
        }
        return r;
    }

    function _dailyBlocked(DecisionInput calldata in_) private pure returns (bool) {
        if (in_.unscoredRevertThreshold == 0 || in_.priorDailyUsd == 0) return false;
        return in_.priorDailyUsd + in_.swapUsd >= in_.unscoredRevertThreshold;
    }

    function _publishedUsdBand(
        uint256 usd,
        uint256 feeThreshold,
        uint256 highThreshold,
        uint24 proportionalFeeBps,
        uint24 punitiveFeeBps
    ) private pure returns (uint24) {
        if (highThreshold != 0 && usd >= highThreshold) return punitiveFeeBps;
        if (feeThreshold != 0 && usd >= feeThreshold) return proportionalFeeBps;
        return 0;
    }

    function _resolveOverrideFee(DecisionInput calldata in_) private pure returns (uint24) {
        if (in_.recommendedFeeBps > 0 && in_.recommendedFeeBps <= FeeBps.MAX_OVERRIDE) {
            return in_.recommendedFeeBps;
        }
        return in_.score >= 55 ? in_.punitiveFeeBps : in_.proportionalFeeBps;
    }
}
