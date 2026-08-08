// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "../interfaces/IRiskPolicy.sol";
import {HookDecision} from "../libraries/HookDecision.sol";

/// @title Layer 3 — RiskPolicy (REAL on-chain decision mapping)
/// @notice Ternary execution decision from whitepaper §3.2 / §3.3:
///         score 0–30 → ALLOW (standard pool fee), 31–70 → FEE_OVERRIDE (EDD economic friction),
///         71–100 → REVERT (unconditional block). Differentiator vs binary allowlists is Output 2.
/// @dev Fee on FEE_OVERRIDE prefers keeper-written `recommendedFeeBps` from ComplianceOracle
///      (typically produced off-chain by the Compliance Officer Agent, then published).
///      Score-band fallback defaults: 8% (~1-hop / N-hop decay ~65) / 3% (~2-hop / ~42)
///      if the keeper wrote 0 or out-of-range.
///      Oracle-latency floors (§3.8 Mitigations B and D: stale+activity, significant inflow)
///      raise ALLOW → FEE_OVERRIDE only; they never soften REVERT or an existing FEE_OVERRIDE.
///      When no keeper fee is present, both floors use LATENCY_FEE_BPS (8%), matching
///      AmlHookLogic and use-case Wallet D. Pure mapping: no storage, no block.timestamp, no calls.
contract RiskPolicy is IRiskPolicy {
    uint24 public constant STANDARD_FEE_BPS = 30; // 0.30% — informational; pool applies base on ALLOW
    uint24 public constant PUNITIVE_FEE_BPS = 800; // 8.00% fallback (~1-hop exposure)
    uint24 public constant PROPORTIONAL_FEE_BPS = 300; // 3.00% fallback (~2-hop exposure)
    uint24 public constant LATENCY_FEE_BPS = 800; // 8.00% — oracle-latency / inflow floor (§3.8)
    uint24 public constant MAX_OVERRIDE_FEE_BPS = 1000; // 10% hard cap

    /// @inheritdoc IRiskPolicy
    /// @notice Maps behavioral score + latency floor signals → ALLOW / FEE_OVERRIDE / REVERT.
    /// @dev Order mirrors §3.3 then §3.8:
    ///      1) score ≥ 71 → REVERT (OFAC / confirmed exploit / direct sanctioned link; no fee).
    ///      2) score 31–70 → FEE_OVERRIDE (medium risk without hard block; RBA / EDD on-chain).
    ///      3) score 0–30 → ALLOW unless a latency floor fires (stale+ops or significant inflow),
    ///         in which case FEE_OVERRIDE at latency fee. Floors do not stack into a harsher tier.
    function decide(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool hasSignificantInflow
    ) external pure returns (HookDecision decision, uint24 feeBps) {
        // §3.3 Output 3 — unconditional block; no ternary discretion once in the high band.
        if (score >= 71) {
            return (HookDecision.REVERT, 0);
        }
        // §3.3 Output 2 — differential fee: monitor / friction without hard-block.
        if (score >= 31) {
            feeBps = _resolveOverrideFee(score, recommendedFeeBps);
            return (HookDecision.FEE_OVERRIDE, feeBps);
        }

        // §3.3 Output 1 (ALLOW band 0–30), then §3.8 floors that may elevate to FEE_OVERRIDE.
        // isStale (Mitigation B) and hasSignificantInflow (Mitigation D) do not stack;
        // either signal alone yields the same FEE_OVERRIDE floor at LATENCY_FEE_BPS.
        bool forceOverride =
            (isStale && operationCount > 0) || hasSignificantInflow;
        if (forceOverride) {
            feeBps = _resolveLatencyFee(recommendedFeeBps);
            return (HookDecision.FEE_OVERRIDE, feeBps);
        }

        return (HookDecision.ALLOW, 0);
    }

    /// @dev Resolve FEE_OVERRIDE fee for the 31–70 band (whitepaper §3.3 / N-hop use case).
    ///      Prefer keeper `recommendedFeeBps`; else score ≥ 55 → 8% (~1-hop), else 3% (~2-hop).
    function _resolveOverrideFee(uint8 score, uint24 recommendedFeeBps)
        private
        pure
        returns (uint24)
    {
        if (recommendedFeeBps > 0 && recommendedFeeBps <= MAX_OVERRIDE_FEE_BPS) {
            return recommendedFeeBps;
        }
        // Score-band fallback if keeper omitted feeBps (demo: 65→8%, 42→3%).
        return score >= 55 ? PUNITIVE_FEE_BPS : PROPORTIONAL_FEE_BPS;
    }

    /// @dev Latency / inflow floor fee (§3.8 Mitigations B & D, Wallet D path).
    ///      Prefer keeper fee; else always 8% — never the 2-hop 3% band fallback.
    function _resolveLatencyFee(uint24 recommendedFeeBps) private pure returns (uint24) {
        if (recommendedFeeBps > 0 && recommendedFeeBps <= MAX_OVERRIDE_FEE_BPS) {
            return recommendedFeeBps;
        }
        return LATENCY_FEE_BPS;
    }
}
