// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";

/// @title Layer 3 — RiskPolicy (REAL on-chain decision mapping)
/// @notice Ternary execution decision from whitepaper §3.2 / §3.3.
///
/// @dev ═══════════════════════════════════════════════════════════════════════
///      WHY A PURE POLICY CONTRACT?
///      ═══════════════════════════════════════════════════════════════════════
///
///      The product differentiator vs binary allowlists is Output 2 (FEE_OVERRIDE):
///      medium risk gets economic friction (EDD) without a hard block.
///
///        Score 0–30  → ALLOW         (standard pool fee, e.g. 0.30%)
///        Score 31–70 → FEE_OVERRIDE  (keeper feeBps, else ~8% / ~3% by hop band)
///        Score 71–100→ REVERT        (exploit / OFAC-grade / direct sanctioned link)
///
///      Oracle-latency floors (§3.8 Mitigations B and D) may raise ALLOW → FEE_OVERRIDE
///      when the score looks clean but the keeper is lagging (stale+activity, significant
///      inflow). Floors never soften REVERT or an existing FEE_OVERRIDE, and they do not
///      stack into a harsher tier — except D's absolute USD floor, which REVERTs.
///
///      Never-scored magnitude (Mitigation A) is decided here from USD-8 amounts the hook
///      quoted via Chainlink: 3% below the fee floor, 8% between floors, REVERT at/above
///      the revert floor. This contract never calls the price feed.
///
///      This contract is pure: no storage, no block.timestamp, no external calls.
///      AmlHookLogic derives isStale / operationCount / hasSignificantInflow /
///      neverScored / assessedUsd / inflowUsd and passes them in.
///
///      No AccessManager: there is nothing to authorize — only math.
contract RiskPolicy is IRiskPolicy {
    uint24 public constant STANDARD_FEE_BPS = FeeBps.STANDARD;
    uint24 public constant PUNITIVE_FEE_BPS = FeeBps.PUNITIVE;
    uint24 public constant PROPORTIONAL_FEE_BPS = FeeBps.PROPORTIONAL;
    uint24 public constant LATENCY_FEE_BPS = FeeBps.LATENCY;
    uint24 public constant MAX_OVERRIDE_FEE_BPS = FeeBps.MAX_OVERRIDE;

    /// @inheritdoc IRiskPolicy
    /// @notice Maps behavioral score + latency floor signals → ALLOW / FEE_OVERRIDE / REVERT.
    /// @dev Evaluation order (must stay this order):
    ///      1) score ≥ 71 → REVERT first (never let a latency floor "rescue" a high score).
    ///      2) never-scored USD bands (3% / 8% / REVERT).
    ///      3) published-score inflow USD ≥ revert floor → REVERT (Mitigation D absolute).
    ///      4) score 31–70 → FEE_OVERRIDE from score bands (Output 2).
    ///      5) score 0–30 → ALLOW unless B (stale+ops) or D relative (inflow) forces FEE_OVERRIDE.
    function decide(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool hasSignificantInflow
    ) external pure returns (HookDecision decision, uint24 feeBps) {
        return _decide(score, recommendedFeeBps, isStale, operationCount, hasSignificantInflow, false, 0, 0, 0, 0);
    }

    /// @inheritdoc IRiskPolicy
    function decide(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool hasSignificantInflow,
        bool neverScored,
        uint256 assessedUsd,
        uint256 inflowUsd,
        uint256 unscoredFeeThreshold,
        uint256 unscoredRevertThreshold
    ) external pure returns (HookDecision decision, uint24 feeBps) {
        return _decide(
            score,
            recommendedFeeBps,
            isStale,
            operationCount,
            hasSignificantInflow,
            neverScored,
            assessedUsd,
            inflowUsd,
            unscoredFeeThreshold,
            unscoredRevertThreshold
        );
    }

    /// @dev Shared mapping for both `decide` overloads. Score ≥ 71 wins before magnitude floors.
    function _decide(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool hasSignificantInflow,
        bool neverScored,
        uint256 assessedUsd,
        uint256 inflowUsd,
        uint256 unscoredFeeThreshold,
        uint256 unscoredRevertThreshold
    ) private pure returns (HookDecision decision, uint24 feeBps) {
        // §3.3 Output 3 — unconditional block. No fee path; no ternary discretion.
        if (score >= 71) {
            return (HookDecision.REVERT, 0);
        }

        // Never-published score: three USD bands. Quote failure is fail-closed in the hook.
        // Published score 0 must arrive as neverScored=false.
        if (neverScored) {
            if (unscoredRevertThreshold != 0 && assessedUsd >= unscoredRevertThreshold) {
                return (HookDecision.REVERT, 0);
            }
            // Below the GAFI-aligned fee floor → reduced 3% latency fee. At/above it (and
            // below revert) → standard 8%. A zero fee floor disables the reduced band.
            if (unscoredFeeThreshold != 0 && assessedUsd < unscoredFeeThreshold) {
                return (HookDecision.FEE_OVERRIDE, FeeBps.PROPORTIONAL);
            }
            return (HookDecision.FEE_OVERRIDE, FeeBps.LATENCY);
        }

        // Mitigation D absolute: inbound USD since baseline at/above the same revert floor.
        // Swap size of already-held clean funds is not `inflowUsd`.
        if (unscoredRevertThreshold != 0 && inflowUsd >= unscoredRevertThreshold) {
            return (HookDecision.REVERT, 0);
        }

        // §3.3 Output 2 — differential fee / EDD friction without hard-block.
        // Prefer keeper-written recommendedFeeBps (COA); else hop-band fallback.
        if (score >= 31) {
            feeBps = _resolveOverrideFee(score, recommendedFeeBps);
            return (HookDecision.FEE_OVERRIDE, feeBps);
        }

        // §3.3 Output 1 (ALLOW band), then §3.8 floors that may elevate.
        // Mitigation B: stale score AND recent pool activity (ops > 0).
        // Mitigation D relative: significant inflow share while oracle still predates baseline.
        // Either alone is enough; both together still only FEE_OVERRIDE (no stacking).
        bool forceOverride = (isStale && operationCount > 0) || hasSignificantInflow;
        if (forceOverride) {
            feeBps = _resolveLatencyFee(recommendedFeeBps);
            return (HookDecision.FEE_OVERRIDE, feeBps);
        }

        // Confirmed low risk (or floors not armed) → pool base fee.
        return (HookDecision.ALLOW, 0);
    }

    /// @dev FEE_OVERRIDE fee for the 31–70 band (whitepaper §3.3 / N-hop use case).
    ///      Prefer keeper `recommendedFeeBps`; else score ≥ 55 → 8% (~1-hop), else 3% (~2-hop).
    ///      Threshold 55 matches demo scores ~65 (1-hop) vs ~42 (2-hop).
    function _resolveOverrideFee(uint8 score, uint24 recommendedFeeBps)
        private
        pure
        returns (uint24)
    {
        if (recommendedFeeBps > 0 && recommendedFeeBps <= FeeBps.MAX_OVERRIDE) {
            return recommendedFeeBps;
        }
        return score >= 55 ? FeeBps.PUNITIVE : FeeBps.PROPORTIONAL;
    }

    /// @dev Latency / inflow floor fee (§3.8 Mitigations B & D, Wallet D path).
    ///      Prefer keeper fee; else always 8% — never the 2-hop 3% band fallback.
    ///      Why 8%: designed economic friction until the keeper catches up.
    function _resolveLatencyFee(uint24 recommendedFeeBps) private pure returns (uint24) {
        return FeeBps.resolveLatencyFee(recommendedFeeBps);
    }
}
