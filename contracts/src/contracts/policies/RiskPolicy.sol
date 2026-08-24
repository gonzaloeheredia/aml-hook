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
///        Score 31–70 → FEE_OVERRIDE  (keeper feeBps if ≤ MAX_OVERRIDE, else live hop fees)
///        Score 71–100→ REVERT        (exploit / OFAC-grade / direct sanctioned link)
///
///      Score cuts 31 / 55 / 71 are fixed in this contract. Floor fees are arguments:
///      the 10-arg `decide` uses `FeeBps.PROPORTIONAL` / `PUNITIVE`; the 12-arg form
///      takes the hook's live `proportionalFeeBps` / `punitiveFeeBps`. `MAX_OVERRIDE`
///      caps only keeper `recommendedFeeBps` on score 31–70, never the floor fees.
///
///      Oracle-latency floors (§3.8 Mitigations B and D) may raise ALLOW → FEE_OVERRIDE
///      when the score looks clean but the keeper is lagging (stale+activity, unpublished
///      inflow). Size then picks the band: under the fee floor → no elevation; between
///      the floors → proportional; at/above the high floor → punitive. Floors never soften
///      REVERT or an existing FEE_OVERRIDE. B and D take the stricter of the two fees;
///      they do not revert.
///
///      Never-scored magnitude (Mitigation A) is decided here from USD-8 amounts the hook
///      quoted via Chainlink: proportional below the fee floor, punitive between floors,
///      REVERT at/above the revert floor. A is this swap only. Floor D's inbound-USD band
///      also runs on that path (the bag), and the stricter of A and D wins. This contract
///      never calls the price feed. Pool-impact (A/B extra) and Floor C live in the hook.
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
///      2) never-scored USD bands (proportional / punitive / REVERT) on this swap,
///         then D bag band (pass / proportional / punitive).
///      3) score 31–70 → FEE_OVERRIDE from score bands (Output 2).
///      4) score 0–30 → ALLOW unless B (stale+ops, swap+hour USD) or D (inflow USD)
///         charges the live floor fees. Neither B nor D reverts. Floor C is hook-local.
    function decide(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool hasSignificantInflow
    ) external pure returns (HookDecision decision, uint24 feeBps) {
        return _decide(
            score,
            recommendedFeeBps,
            isStale,
            operationCount,
            hasSignificantInflow,
            false,
            0,
            0,
            0,
            0,
            FeeBps.PROPORTIONAL,
            FeeBps.PUNITIVE
        );
    }

    /// @inheritdoc IRiskPolicy
    /// @dev Default floor fees (`FeeBps.PROPORTIONAL` / `PUNITIVE`). Hook path uses the 12-arg form.
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
            unscoredRevertThreshold,
            FeeBps.PROPORTIONAL,
            FeeBps.PUNITIVE
        );
    }

    /// @inheritdoc IRiskPolicy
    /// @dev Live floor fees from the hook. `MAX_OVERRIDE` still applies only to keeper `recommendedFeeBps`.
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
        uint256 unscoredRevertThreshold,
        uint24 proportionalFeeBps,
        uint24 punitiveFeeBps
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
            unscoredRevertThreshold,
            proportionalFeeBps,
            punitiveFeeBps
        );
    }

    /// @dev Shared mapping for every `decide` overload. Score ≥ 71 wins before magnitude floors.
    function _decide(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool,
        bool neverScored,
        uint256 assessedUsd,
        uint256 inflowUsd,
        uint256 unscoredFeeThreshold,
        uint256 unscoredRevertThreshold,
        uint24 proportionalFeeBps,
        uint24 punitiveFeeBps
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
            // A: this swap. D: inbound bag (baseline 0 on first contact). Stricter fee wins.
            uint24 aFee = (unscoredFeeThreshold != 0 && assessedUsd < unscoredFeeThreshold)
                ? proportionalFeeBps
                : punitiveFeeBps;
            uint24 bagFee = _publishedUsdBand(
                inflowUsd, unscoredFeeThreshold, unscoredRevertThreshold, proportionalFeeBps, punitiveFeeBps
            );
            feeBps = aFee > bagFee ? aFee : bagFee;
            return (HookDecision.FEE_OVERRIDE, feeBps);
        }

        // §3.3 Output 2 — differential fee / EDD friction without hard-block.
        // Prefer keeper-written recommendedFeeBps (COA); else hop-band fallback.
        if (score >= 31) {
            feeBps = _resolveOverrideFee(score, recommendedFeeBps, proportionalFeeBps, punitiveFeeBps);
            return (HookDecision.FEE_OVERRIDE, feeBps);
        }

        // §3.3 Output 1 (ALLOW band), then §3.8 B/D USD bands (pass / proportional / punitive).
        // B uses swap+window `assessedUsd`. D uses inbound `inflowUsd` (not held funds).
        // `hasSignificantInflow` is not a fee trigger; the hook still emits it for audit.
        // A zero high threshold disables the 8% band; a zero fee threshold disables 3%.
        uint24 bFee = 0;
        if (isStale && operationCount > 0) {
            bFee = _publishedUsdBand(
                assessedUsd, unscoredFeeThreshold, unscoredRevertThreshold, proportionalFeeBps, punitiveFeeBps
            );
        }
        uint24 dFee = _publishedUsdBand(
            inflowUsd, unscoredFeeThreshold, unscoredRevertThreshold, proportionalFeeBps, punitiveFeeBps
        );
        feeBps = bFee > dFee ? bFee : dFee;
        if (feeBps > 0) {
            return (HookDecision.FEE_OVERRIDE, feeBps);
        }

        // Confirmed low risk (or floors not armed / dust) → pool base fee.
        return (HookDecision.ALLOW, 0);
    }

    /// @dev Published-wallet B/D band: dust → 0 (pass); mid → proportional; high → punitive.
    function _publishedUsdBand(
        uint256 usd,
        uint256 feeThreshold,
        uint256 highThreshold,
        uint24 proportionalFeeBps,
        uint24 punitiveFeeBps
    ) private pure returns (uint24) {
        if (highThreshold != 0 && usd >= highThreshold) {
            return punitiveFeeBps;
        }
        if (feeThreshold != 0 && usd >= feeThreshold) {
            return proportionalFeeBps;
        }
        return 0;
    }

    /// @dev FEE_OVERRIDE fee for the 31–70 band (whitepaper §3.3 / N-hop use case).
    ///      Prefer keeper `recommendedFeeBps` when ≤ `MAX_OVERRIDE`; else score ≥ 55
    ///      uses the live punitive floor fee, else the live proportional floor fee.
    ///      `MAX_OVERRIDE` never caps the floor fees themselves.
    function _resolveOverrideFee(
        uint8 score,
        uint24 recommendedFeeBps,
        uint24 proportionalFeeBps,
        uint24 punitiveFeeBps
    ) private pure returns (uint24) {
        if (recommendedFeeBps > 0 && recommendedFeeBps <= FeeBps.MAX_OVERRIDE) {
            return recommendedFeeBps;
        }
        return score >= 55 ? punitiveFeeBps : proportionalFeeBps;
    }
}
