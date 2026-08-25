// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Layer 1 — on-chain sanctions screen
/// @notice Static OFAC/SDN-style list (whitepaper §3.2 Layer 1 / §4.1).
///         Fail-closed: a hit means the hook must REVERT (`SanctionHit`) before reading the score.
/// @dev The COA downloads the public OFAC SDN dump off-chain and writes matches via
///      `setSanctioned` (demo Wallet F). `beforeSwap` only reads this mapping — it never
///      calls Treasury. Demo Wallet A is an exploit score 100, not a list hit.
interface ISanctionRegistry {
    /// @notice Emitted when a single address sanction flag is written.
    event SanctionUpdated(address indexed account, bool sanctioned);

    /// @notice True if `account` is sanctioned / blocked at Layer 1.
    function isSanctioned(address account) external view returns (bool);

    /// @notice Admin / ops writes a single address (event-driven list maintenance).
    /// @dev Immediate emergency path. Production listings should use commit-reveal
    ///      (`commitSanction` + `revealSanction`) to reduce mempool front-running.
    function setSanctioned(address account, bool sanctioned) external;
}
