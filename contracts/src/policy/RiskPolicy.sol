// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "../interfaces/IRiskPolicy.sol";
import {HookDecision} from "../libraries/HookDecision.sol";

/// @title Layer 3 — RiskPolicy (REAL on-chain decision mapping)
/// @notice Fixed product bands: 0–30 ALLOW, 31–70 FEE_OVERRIDE, 71–100 REVERT.
/// @dev Fee on FEE_OVERRIDE prefers keeper-written `recommendedFeeBps` from ComplianceOracle.
///      (Off-chain, that value is typically produced by the Compliance Officer Agent, then published.)
///      Falls back to demo defaults (8% / 3%) only if the keeper wrote 0 or out-of-range.
///      Oracle-latency floors (stale+activity, significant inflow) raise ALLOW to FEE_OVERRIDE only;
///      they never soften REVERT or an existing FEE_OVERRIDE. Both floors share the same minimum tier.
contract RiskPolicy is IRiskPolicy {
    uint24 public constant STANDARD_FEE_BPS = 30; // 0.30% — informational; pool applies base on ALLOW
    uint24 public constant PUNITIVE_FEE_BPS = 800; // 8.00% fallback (~1-hop)
    uint24 public constant PROPORTIONAL_FEE_BPS = 300; // 3.00% fallback (~2-hop)
    uint24 public constant MAX_OVERRIDE_FEE_BPS = 1000; // 10% hard cap

    /// @inheritdoc IRiskPolicy
    function decide(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool hasSignificantInflow
    ) external pure returns (HookDecision decision, uint24 feeBps) {
        if (score >= 71) {
            return (HookDecision.REVERT, 0);
        }
        if (score >= 31) {
            feeBps = _resolveOverrideFee(score, recommendedFeeBps);
            return (HookDecision.FEE_OVERRIDE, feeBps);
        }

        // ALLOW band (0–30): apply latency floors. isStale and hasSignificantInflow do not stack;
        // either signal alone yields the same FEE_OVERRIDE floor.
        bool forceOverride =
            (isStale && operationCount > 0) || hasSignificantInflow;
        if (forceOverride) {
            feeBps = _resolveOverrideFee(score, recommendedFeeBps);
            return (HookDecision.FEE_OVERRIDE, feeBps);
        }

        return (HookDecision.ALLOW, 0);
    }

    function _resolveOverrideFee(uint8 score, uint24 recommendedFeeBps)
        private
        pure
        returns (uint24)
    {
        if (recommendedFeeBps > 0 && recommendedFeeBps <= MAX_OVERRIDE_FEE_BPS) {
            return recommendedFeeBps;
        }
        // Legacy fallback if keeper omitted feeBps
        return score >= 55 ? PUNITIVE_FEE_BPS : PROPORTIONAL_FEE_BPS;
    }
}
