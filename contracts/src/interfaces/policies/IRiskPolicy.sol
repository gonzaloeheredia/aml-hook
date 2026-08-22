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
    ///        FEE_OVERRIDE when in range; else score-band or latency fallbacks apply.
    /// @param isStale True when the hook determined the stored score exceeds stalenessThreshold
    ///        (Mitigation B). With `operationCount > 0`, floors ALLOW → FEE_OVERRIDE.
    /// @param operationCount Ops recorded for the wallet in the hook's current activity window.
    /// @param hasSignificantInflow True when beforeSwap detected a large balance increase not yet
    ///        reflected in the oracle score timestamp (Mitigation D / Wallet D). Floors ALLOW →
    ///        FEE_OVERRIDE at the latency fee (8%) when no in-range recommendedFeeBps is present.
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
    /// @dev `neverScored` (`updatedAt == 0`):
    ///        assessedUsd < feeThreshold     → FEE_OVERRIDE at 3% (GAFI-aligned dust / CDD band)
    ///        feeThreshold ≤ assessedUsd < revertThreshold → FEE_OVERRIDE at 8%
    ///        assessedUsd ≥ revertThreshold  → REVERT
    ///      Published score: REVERT when Mitigation D `inflowUsd` (inbound tokens since baseline,
    ///      quoted to USD) is at/above `revertThreshold` — not the swap size of already-held funds.
    ///      A zero `revertThreshold` disables the hard block. Quote failure is handled by the hook
    ///      (fail-closed), not by this function.
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
}
