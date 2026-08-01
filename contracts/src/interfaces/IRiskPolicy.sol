// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookDecision} from "../libraries/HookDecision.sol";

/// @title Layer 3 — maps score → ternary hook output
/// @notice Pure policy: no storage of per-wallet state.
interface IRiskPolicy {
    /// @notice Decide ALLOW / FEE_OVERRIDE / REVERT from a 0–100 score.
    /// @return decision Ternary output for the hook.
    /// @return feeBps Fee in basis points when FEE_OVERRIDE (else 0). Standard pool fee is applied on ALLOW by the pool, not here.
    function decide(uint8 score)
        external
        view
        returns (HookDecision decision, uint24 feeBps);
}
