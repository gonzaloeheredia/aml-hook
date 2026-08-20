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
        Blocked,
        ReleasedDefault,
        Recovered
    }

    /// @notice One retained FEE_OVERRIDE fee slice.
    struct EscrowRecord {
        address wallet;
        uint256 amount;
        uint64 depositedAt;
        bytes32 swapFingerprint;
        EscrowStatus status;
    }

    /// @notice ERC-20 this escrow custodies (must match the swap fee currency to deposit).
    function feeToken() external view returns (address);

    /// @notice Next escrow id that `deposit` will assign (starts at 1).
    function nextEscrowId() external view returns (uint256);

    /// @notice Deposit the differential fee into the 48h escrow.
    /// @dev Only an authorized depositor (e.g. settlement path). Pulls `feeToken` via transferFrom.
    /// @return escrowId Identifier for later keeper resolution.
    function deposit(address wallet, bytes32 swapFingerprint, uint256 amount)
        external
        returns (uint256 escrowId);

    /// @notice Checkpoint 1 (~24h): early credit to `lpCompensationFund`. Never blocks; never the pool.
    function releaseEarly(uint256 escrowId) external;

    /// @notice Checkpoint 2 (at/after 48h): COA-backed final resolution by the keeper.
    /// @param illicitConfirmed True → fee stays blocked in escrow; false → lpCompensationFund (never the pool).
    function resolveCheckpoint2(uint256 escrowId, bool illicitConfirmed) external;

    /// @notice After the window with no prior resolution: credit LPs (`lpCompensationFund`).
    /// @dev Wallet was not confirmed high-risk or sanctioned — same destination as Checkpoint 2 clean.
    function releaseDefault(uint256 escrowId) external;

    /// @notice Checkpoint 1 for many escrow ids (same rules as `releaseEarly`).
    function batchReleaseEarly(uint256[] calldata escrowIds) external;

    /// @notice Checkpoint 2 for many escrow ids. `illicitConfirmed` must match `escrowIds` 1:1.
    function batchResolveCheckpoint2(uint256[] calldata escrowIds, bool[] calldata illicitConfirmed)
        external;

    /// @notice Default release for many escrow ids (same rules as `releaseDefault`).
    function batchReleaseDefault(uint256[] calldata escrowIds) external;

    /// @notice Owner recovery of a blocked fee to lpCompensationFund (exceptional; no batch).
    function recoverBlocked(uint256 escrowId) external;

    /// @notice Read a single escrow record.
    function getEscrow(uint256 escrowId) external view returns (EscrowRecord memory);
}
