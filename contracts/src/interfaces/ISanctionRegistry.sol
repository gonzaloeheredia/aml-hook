// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Layer 1 — on-chain sanctions screen
/// @notice Fail-closed: a hit means the hook must REVERT before reading the score.
interface ISanctionRegistry {
    /// @notice True if `account` is sanctioned / blocked at Layer 1.
    function isSanctioned(address account) external view returns (bool);

    /// @notice Admin / keeper updates a single address flag.
    function setSanctioned(address account, bool sanctioned) external;
}
