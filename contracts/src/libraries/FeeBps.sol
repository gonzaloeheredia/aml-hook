// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Shared fee constants and latency-fee resolution
/// @notice Single source for pool base, latency floor, and override cap (whitepaper §3.3 / §3.8).
/// @dev RiskPolicy (mitigations B/D) and AmlHookLogic (A/C) must not drift. AmlHook uses
///      `STANDARD` to compute the FeeEscrow differential as `max(0, feeBps - STANDARD)`.
library FeeBps {
    /// @notice Pool base LP fee (0.30%). Not overridden in beforeSwap.
    uint24 internal constant STANDARD = 30;

    /// @notice 1-hop / punitive fallback and default latency floor (8.00%).
    uint24 internal constant PUNITIVE = 800;

    /// @notice 2-hop proportional fallback (3.00%).
    uint24 internal constant PROPORTIONAL = 300;

    /// @notice Oracle-latency / inflow floor when the keeper omitted a usable fee (§3.8).
    uint24 internal constant LATENCY = 800;

    /// @notice Hard cap on any keeper-written override (10%).
    uint24 internal constant MAX_OVERRIDE = 1000;

    /// @notice Floor for Mitigation D `inflowThresholdBps` (1%). Governor cannot set 0.
    uint256 internal constant MIN_INFLOW_THRESHOLD = 100;

    /// @notice Ceiling for Mitigation D `inflowThresholdBps` (100% of current balance).
    uint256 internal constant MAX_INFLOW_THRESHOLD = 10_000;

    /// @notice Prefer in-range keeper `recommendedFeeBps`; else the 8% latency floor.
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
