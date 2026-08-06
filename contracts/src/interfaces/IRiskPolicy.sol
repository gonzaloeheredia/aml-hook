// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookDecision} from "../libraries/HookDecision.sol";

/// @title Layer 3 — maps score → ternary hook output
/// @notice Pure policy: no storage of per-wallet state.
interface IRiskPolicy {
    /// @notice Decide ALLOW / FEE_OVERRIDE / REVERT from a 0–100 score.
    /// @param score Behavioral score from ComplianceOracle.
    /// @param recommendedFeeBps Keeper-written fee (bps) from ComplianceOracle. Used on FEE_OVERRIDE when in range.
    /// @return decision Ternary output for the hook.
    /// @return feeBps Fee in basis points when FEE_OVERRIDE (else 0). Pool base fee applies on ALLOW.
    function decide(uint8 score, uint24 recommendedFeeBps)
        external
        view
        returns (HookDecision decision, uint24 feeBps);
}
