// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookDecision} from "../../libraries/HookDecision.sol";

/// @title Layer 3 — maps score → ternary hook output
/// @notice Pure policy (whitepaper §3.2 Layer 3 / §3.3): no per-wallet storage.
///         Latency signals (§3.8) are computed by the hook and passed in; this contract
///         never reads `block.timestamp` or makes external calls.
interface IRiskPolicy {
    /// @notice Decide ALLOW / FEE_OVERRIDE / REVERT from score plus oracle-latency floor signals.
    /// @param score Behavioral score from ComplianceOracle (0–100). Bands: 0–30 ALLOW,
    ///        31–70 FEE_OVERRIDE (EDD friction), 71–100 REVERT (§3.3).
    /// @param recommendedFeeBps Keeper-written fee (bps) from ComplianceOracle. Used on
    ///        FEE_OVERRIDE when 0 < fee ≤ `FeeBps.MAX_OVERRIDE`; else hop-band fallback.
    /// @param isStale True when the hook determined the stored score exceeds stalenessThreshold
    ///        (Mitigation B). With `operationCount > 0`, Floor B bands swap+window USD on the
    ///        long `decide` overload (pass / proportional / punitive). This 5-arg form has no USD and does not elevate.
    /// @param operationCount Ops recorded for the wallet in the hook's current activity window.
    /// @param hasSignificantInflow Kept for ABI compatibility. Not a fee trigger. Mitigation D
    ///        uses `inflowUsd` bands (pass / proportional / punitive) on the long `decide` overload.
    /// @return decision Ternary output for the hook.
    /// @return feeBps Fee in basis points when FEE_OVERRIDE (else 0). Pool base fee applies on ALLOW.
    function decide(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool hasSignificantInflow
    ) external pure returns (HookDecision decision, uint24 feeBps);

    /// @notice Same mapping, plus USD magnitude floors (Chainlink 8 decimals).
    /// @dev Uses default `FeeBps.PROPORTIONAL` / `PUNITIVE` for A/B/D bands.
    ///      `neverScored` (`updatedAt == 0`):
    ///        assessedUsd < feeThreshold     → FEE_OVERRIDE at the proportional fee
    ///        feeThreshold ≤ assessedUsd < revertThreshold → FEE_OVERRIDE at the punitive fee
    ///        assessedUsd ≥ revertThreshold  → REVERT
    ///      Floor D still runs: `inflowUsd` (the current bag when there is no baseline) uses
    ///      pass / proportional / punitive. The stricter of A and D is returned. Pool-impact
    ///      lives in the hook. `assessedUsd` is this swap for Floor A. Published score (B/D):
    ///      neither floor reverts. Floor B uses swap + hour USD when the score is stale and
    ///      `operationCount > 0`. Dust (below the fee floor) → no elevation; mid → proportional;
    ///      at/above `unscoredRevertThreshold` → punitive. A zero high threshold still disables
    ///      the punitive band in this pure function; the hook setter cannot store that pair.
    ///      Quote failure is handled by the hook (fail-closed), not by this function.
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
    ) external pure returns (HookDecision decision, uint24 feeBps);

    /// @notice Same mapping as the 10-arg form, with live floor fees from the hook.
    /// @dev `proportionalFeeBps` / `punitiveFeeBps` replace the default 3% / 8% constants on
    ///      A/B/D bands and on the 31–70 hop fallback when the keeper omitted a usable fee.
    ///      `FeeBps.MAX_OVERRIDE` still caps only keeper `recommendedFeeBps` on score 31–70.
    ///      Score cuts 31 / 55 / 71 stay hardcoded.
    /// @param proportionalFeeBps Live mid-band floor fee from the hook.
    /// @param punitiveFeeBps Live high-band floor fee from the hook.
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
    ) external pure returns (HookDecision decision, uint24 feeBps);
}
