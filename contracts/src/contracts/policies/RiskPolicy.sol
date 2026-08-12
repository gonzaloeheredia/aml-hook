// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
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
///      stack into a harsher tier.
///
///      This contract is pure: no storage, no block.timestamp, no external calls.
///      AmlHookLogic derives isStale / operationCount / hasSignificantInflow and passes
///      them in. That keeps RiskPolicy auditable as a pure function of its inputs.
///
///      No AccessManager: there is nothing to authorize — only math.
contract RiskPolicy is IRiskPolicy {
    uint24 public constant STANDARD_FEE_BPS = 30; // 0.30% — informational; pool applies base on ALLOW
    uint24 public constant PUNITIVE_FEE_BPS = 800; // 8.00% fallback (~1-hop / score ~65)
    uint24 public constant PROPORTIONAL_FEE_BPS = 300; // 3.00% fallback (~2-hop / score ~42)
    uint24 public constant LATENCY_FEE_BPS = 800; // 8.00% — oracle-latency / inflow floor (§3.8)
    uint24 public constant MAX_OVERRIDE_FEE_BPS = 1000; // 10% hard cap on any override

    /// @inheritdoc IRiskPolicy
    /// @notice Maps behavioral score + latency floor signals → ALLOW / FEE_OVERRIDE / REVERT.
    /// @dev Evaluation order (must stay this order):
    ///      1) score ≥ 71 → REVERT first (never let a latency floor "rescue" a high score).
    ///      2) score 31–70 → FEE_OVERRIDE from score bands (Output 2).
    ///      3) score 0–30 → ALLOW unless B (stale+ops) or D (inflow) forces FEE_OVERRIDE.
    function decide(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool hasSignificantInflow
    ) external pure returns (HookDecision decision, uint24 feeBps) {
        // §3.3 Output 3 — unconditional block. No fee path; no ternary discretion.
        if (score >= 71) {
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
        // Mitigation D: significant inflow while oracle still predates baseline.
        // Either alone is enough; both together still only FEE_OVERRIDE (no stacking).
        bool forceOverride =
            (isStale && operationCount > 0) || hasSignificantInflow;
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
        if (recommendedFeeBps > 0 && recommendedFeeBps <= MAX_OVERRIDE_FEE_BPS) {
            return recommendedFeeBps;
        }
        return score >= 55 ? PUNITIVE_FEE_BPS : PROPORTIONAL_FEE_BPS;
    }

    /// @dev Latency / inflow floor fee (§3.8 Mitigations B & D, Wallet D path).
    ///      Prefer keeper fee; else always 8% — never the 2-hop 3% band fallback.
    ///      Why 8%: designed economic friction until the keeper catches up.
    function _resolveLatencyFee(uint24 recommendedFeeBps) private pure returns (uint24) {
        if (recommendedFeeBps > 0 && recommendedFeeBps <= MAX_OVERRIDE_FEE_BPS) {
            return recommendedFeeBps;
        }
        return LATENCY_FEE_BPS;
    }
}
