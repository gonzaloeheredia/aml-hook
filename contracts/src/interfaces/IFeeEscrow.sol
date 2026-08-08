// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Fee escrow for FEE_OVERRIDE differential fees (whitepaper §3.7)
/// @notice Holds only the differential fee for 48h with keeper-driven checkpoints.
///         The Compliance Officer Agent (COA) has no write path on this contract.
interface IFeeEscrow {
    /// @notice Lifecycle of one escrowed differential-fee deposit.
    enum EscrowStatus {
        Active,
        ReleasedEarly,
        Confiscated,
        ReleasedDefault
    }

    /// @notice One retained FEE_OVERRIDE fee slice.
    struct EscrowRecord {
        address wallet;
        uint256 amount;
        uint64 depositedAt;
        bytes32 originTxHash;
        EscrowStatus status;
    }

    /// @notice Deposit the differential fee into the 48h escrow.
    /// @dev Only an authorized depositor (e.g. settlement path). Pulls `feeToken` via transferFrom.
    /// @return escrowId Identifier for later keeper resolution.
    function deposit(address wallet, bytes32 originTxHash, uint256 amount)
        external
        returns (uint256 escrowId);

    /// @notice Checkpoint 1 (~24h): early release to the pool. Never confiscates.
    function releaseEarly(uint256 escrowId) external;

    /// @notice Checkpoint 2 (at/after 48h): COA-backed final resolution by the keeper.
    /// @param illicitConfirmed True → LP compensation fund (never the pool); false → pool.
    function resolveCheckpoint2(uint256 escrowId, bool illicitConfirmed) external;

    /// @notice Default release to the pool after the window with no prior resolution.
    function releaseDefault(uint256 escrowId) external;

    /// @notice Read a single escrow record.
    function getEscrow(uint256 escrowId) external view returns (EscrowRecord memory);
}
