// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "../interfaces/policies/IRiskPolicy.sol";
import {FeeBps} from "./FeeBps.sol";
import {HookDecision} from "./HookDecision.sol";

/// @title RiskPolicyLib — pure compliance decision engine (Layer 3)
/// @notice Maps a published COA score + floor signals A–D to ALLOW / FEE_OVERRIDE / REVERT.
/// @dev Pure: one memory pointer in, one result out. No storage, no external calls, no agent.
library RiskPolicyLib {
    /// @notice Apply the full ternary decision tree to a pre-gathered signal set.
    /// @dev Call order: score band → never-scored / allow-band → stale-pool-impact → daily gate.
    ///      A daily-aggregation block can override an ALLOW or FEE_OVERRIDE but never a REVERT.
    /// @param in_ Packed signal struct built by `AmlHookLogic._toInput`.
    /// @return r  Decision, override fee, and revert kind (None when decision ≠ REVERT).
    function decide(IRiskPolicy.DecisionInput memory in_)
        internal
        pure
        returns (IRiskPolicy.DecisionResult memory r)
    {
        if (in_.score >= 71) {
            return IRiskPolicy.DecisionResult(HookDecision.REVERT, 0, IRiskPolicy.RevertKind.ScoreBand);
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
            return IRiskPolicy.DecisionResult(HookDecision.REVERT, 0, IRiskPolicy.RevertKind.DailyAggregation);
        }
    }

    /// @dev Floor A: wallet has no score on-chain. Apply magnitude / pool-impact / inflow floors.
    ///      UnscoredMagnitude REVERT takes precedence over UnscoredPoolImpact REVERT.
    function _neverScored(IRiskPolicy.DecisionInput memory in_)
        private
        pure
        returns (IRiskPolicy.DecisionResult memory r)
    {
        if (in_.unscoredRevertThreshold != 0 && in_.assessedUsd >= in_.unscoredRevertThreshold) {
            return IRiskPolicy.DecisionResult(HookDecision.REVERT, 0, IRiskPolicy.RevertKind.UnscoredMagnitude);
        }
        uint24 aFee = (in_.unscoredFeeThreshold != 0 && in_.assessedUsd < in_.unscoredFeeThreshold)
            ? in_.proportionalFeeBps
            : in_.punitiveFeeBps;
        uint24 bagFee = _publishedUsdBand(
            in_.inflowUsd,
            in_.unscoredFeeThreshold,
            in_.unscoredRevertThreshold,
            in_.proportionalFeeBps,
            in_.punitiveFeeBps
        );
        r.decision = HookDecision.FEE_OVERRIDE;
        r.feeBps = aFee > bagFee ? aFee : bagFee;

        if (in_.poolImpactThresholdBps != 0 && in_.poolImpactBps > in_.poolImpactThresholdBps) {
            if (r.feeBps >= in_.punitiveFeeBps) {
                return IRiskPolicy.DecisionResult(HookDecision.REVERT, 0, IRiskPolicy.RevertKind.UnscoredPoolImpact);
            }
            r.feeBps = in_.punitiveFeeBps;
        }
    }

    /// @dev Floor B (stale activity) and Floor D (inflow heuristic) for the 0–30 score band.
    ///      Returns ALLOW when neither floor triggers; FEE_OVERRIDE otherwise.
    function _allowBand(IRiskPolicy.DecisionInput memory in_)
        private
        pure
        returns (IRiskPolicy.DecisionResult memory r)
    {
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
            in_.inflowUsd,
            in_.unscoredFeeThreshold,
            in_.unscoredRevertThreshold,
            in_.proportionalFeeBps,
            in_.punitiveFeeBps
        );
        r.feeBps = bFee > dFee ? bFee : dFee;
        if (r.feeBps > 0) r.decision = HookDecision.FEE_OVERRIDE;
    }

    /// @dev Floor B extra: stale + pool drain hardens pass→mid, mid→high. Never REVERT. No ops gate (H-01).
    function _applyStalePoolImpact(IRiskPolicy.DecisionInput memory in_, IRiskPolicy.DecisionResult memory r)
        private
        pure
        returns (IRiskPolicy.DecisionResult memory)
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

    /// @dev Floor C: daily rolling USD (prior + this swap) meets or exceeds `unscoredRevertThreshold`.
    function _dailyBlocked(IRiskPolicy.DecisionInput memory in_) private pure returns (bool) {
        if (in_.unscoredRevertThreshold == 0 || in_.priorDailyUsd == 0) return false;
        return in_.priorDailyUsd + in_.swapUsd >= in_.unscoredRevertThreshold;
    }

    /// @dev Maps a USD amount to a fee tier: punitive if `usd >= highThreshold`,
    ///      proportional if `usd >= feeThreshold`, else 0.
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

    /// @notice Published COA fee when usable; else 8% (≥ 55) or 3% (31–54). Used by swap L3 and the LP module.
    function overrideFeeBps(IRiskPolicy.DecisionInput memory in_) internal pure returns (uint24) {
        return _resolveOverrideFee(in_);
    }

    /// @dev Prefer COA `recommendedFeeBps` published by the keeper when 0 < fee ≤ `MAX_OVERRIDE`; else punitive (≥ 55) or proportional.
    function _resolveOverrideFee(IRiskPolicy.DecisionInput memory in_) private pure returns (uint24) {
        if (in_.recommendedFeeBps > 0 && in_.recommendedFeeBps <= FeeBps.MAX_OVERRIDE) {
            return in_.recommendedFeeBps;
        }
        return in_.score >= 55 ? in_.punitiveFeeBps : in_.proportionalFeeBps;
    }
}
