// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookDecision} from "../libraries/HookDecision.sol";

/// @title Layer 3 — maps score → ternary hook output
/// @notice Pure policy: no storage of per-wallet state. Latency signals are computed by the hook
///         and passed in; this contract never reads block.timestamp or makes external calls.
interface IRiskPolicy {
    /// @notice Decide ALLOW / FEE_OVERRIDE / REVERT from score plus oracle-latency floor signals.
    /// @param score Behavioral score from ComplianceOracle (0–100).
    /// @param recommendedFeeBps Keeper-written fee (bps) from ComplianceOracle. Used on FEE_OVERRIDE when in range.
    /// @param isStale True when the hook determined the stored score exceeds stalenessThreshold.
    /// @param operationCount Ops recorded for the wallet in the hook's current activity window.
    /// @param hasSignificantInflow True when beforeSwap detected a large balance increase not yet
    ///        reflected in the oracle score timestamp.
    /// @return decision Ternary output for the hook.
    /// @return feeBps Fee in basis points when FEE_OVERRIDE (else 0). Pool base fee applies on ALLOW.
    function decide(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool hasSignificantInflow
    ) external pure returns (HookDecision decision, uint24 feeBps);
}
