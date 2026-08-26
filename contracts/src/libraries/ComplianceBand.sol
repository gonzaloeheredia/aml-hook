// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Shared score-band cuts used by the hook and FeeEscrow Checkpoint 2.
/// @dev Keep in lockstep with `RiskPolicyLib` (score ≥ 71 → REVERT / illicit).
library ComplianceBand {
    /// @notice Inclusive lower bound of the REVERT / illicit score band.
    uint8 internal constant SCORE_REVERT = 71;

    /// @notice True when a published COA score is in the REVERT band.
    function isIllicitScore(uint8 score) internal pure returns (bool) {
        return score >= SCORE_REVERT;
    }
}
