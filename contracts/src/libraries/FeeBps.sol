// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Shared fee constants and latency-fee resolution
/// @notice Default fee constants and COA-fee resolution (whitepaper §3.3 / §3.8).
/// @dev `STANDARD` is fixed (pool base). `PROPORTIONAL` / `PUNITIVE` / `LATENCY` are
///      deploy defaults; the hook stores live floor fees that may differ.
///      `MAX_OVERRIDE` caps only the COA `recommendedFeeBps` the keeper published on
///      score 31–70, never the live floor fees. AmlHook uses `STANDARD` for the
///      FeeEscrow differential.
library FeeBps {
    /// @notice Pool base LP fee (0.30%). Not overridden in beforeSwap.
    uint24 internal constant STANDARD = 30;

    /// @notice 1-hop / punitive fallback and default latency floor (8.00%).
    uint24 internal constant PUNITIVE = 800;

    /// @notice 2-hop proportional fallback (3.00%).
    uint24 internal constant PROPORTIONAL = 300;

    /// @notice Oracle-latency / inflow floor when the published COA fee is unusable (§3.8).
    uint24 internal constant LATENCY = 800;

    /// @notice Hard cap on COA `recommendedFeeBps` published by the keeper in the 31–70 band (10%).
    /// @dev Fixed constant. No role may retune it. Does not apply to floor USD or floor fees.
    uint24 internal constant MAX_OVERRIDE = 1000;

    /// @notice Floor for Mitigation D `inflowThresholdBps` (1%). Governor cannot set 0.
    uint256 internal constant MIN_INFLOW_THRESHOLD = 100;

    /// @notice Ceiling for Mitigation D `inflowThresholdBps` (100% of current balance).
    uint256 internal constant MAX_INFLOW_THRESHOLD = 10_000;

    /// @notice Prefer published COA `recommendedFeeBps` when 0 < fee ≤ `MAX_OVERRIDE`; else default latency.
    function resolveLatencyFee(uint24 recommendedFeeBps) internal pure returns (uint24) {
        if (recommendedFeeBps > 0 && recommendedFeeBps <= MAX_OVERRIDE) {
            return recommendedFeeBps;
        }
        return LATENCY;
    }

    /// @notice Risk-fee slice above the pool base (bps). Zero when `feeBps` is not an override.
    function differentialBps(uint24 feeBps) internal pure returns (uint256) {
        return feeBps > STANDARD ? uint256(feeBps) - uint256(STANDARD) : 0;
    }

    /// @notice Differential amount charged on `basisAmount` (`basis * differentialBps / 10_000`).
    function differentialAmount(uint256 basisAmount, uint24 feeBps) internal pure returns (uint256) {
        uint256 bps = differentialBps(feeBps);
        if (bps == 0 || basisAmount == 0) return 0;
        return (basisAmount * bps) / 10_000;
    }
}
