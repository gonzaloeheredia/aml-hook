// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Fee escrow for extra risk fees and seized LP principal (whitepaper §8.3)
/// @notice Holds the extra slice, LP-add risk fee, and seized LP capital for 48 hours.
///         The Compliance Officer Agent cannot write here.
interface IFeeEscrow {
    /// @notice Lifecycle of one escrowed differential-fee or LP-principal deposit.
    enum EscrowStatus {
        Active,
        ReleasedEarly,
        Blocked,
        ReleasedDefault,
        Recovered
    }

    /// @notice Risk-fee slice (swap or LP add / remove feesAccrued) vs seized LP principal.
    /// @dev Clean risk fee → LP compensation fund. Clean principal → the LP wallet.
    ///      Illicit recover: fee → `ILLICIT_RISK_FEE`; principal → `LP_PRINCIPAL`.
    enum EscrowKind {
        RiskFee,
        LpPrincipal
    }

    /// @notice One extra slice from a fee-override swap, LP add, or seized LP exit.
    struct EscrowRecord {
        address wallet;
        address token;
        uint256 amount;
        uint64 depositedAt;
        bytes32 swapFingerprint;
        EscrowStatus status;
        uint64 blockedAt;
        EscrowKind kind;
    }

    /// @notice Default / constructor ERC-20. Additional tokens may be enabled via `allowedFeeTokens`.
    function feeToken() external view returns (address);

    /// @notice True if `token` is accepted as a custody asset.
    function allowedFeeTokens(address token) external view returns (bool);

    /// @notice Amount of `token` currently retained for `wallet` (Active + Blocked).
    function balances(address wallet, address token) external view returns (uint256);

    /// @notice Next escrow id that `deposit` will assign (starts at 1).
    function nextEscrowId() external view returns (uint256);

    /// @notice Deposit the extra slice for 48 hours. Only the hook (the depositor) may call this.
    ///         Defaults to `EscrowKind.RiskFee`.
    function deposit(address wallet, address token, bytes32 swapFingerprint, uint256 amount)
        external
        returns (uint256 escrowId);

    /// @notice Deposit with an explicit kind (`RiskFee` or `LpPrincipal`).
    function deposit(address wallet, address token, bytes32 swapFingerprint, uint256 amount, EscrowKind kind)
        external
        returns (uint256 escrowId);

    /// @notice 24–48h: early release. Risk fee → LP compensation fund. Principal → the LP wallet.
    ///         Never blocks. Never the pool.
    function releaseEarly(uint256 escrowId) external;

    /// @notice At 48h: destination is read from SanctionRegistry / ComplianceOracle, not a keeper bool.
    ///         List hit or score ≥ 71 → Blocked. Otherwise risk fee → LP compensation fund;
    ///         principal → the LP wallet.
    function resolveCheckpoint2(uint256 escrowId) external;

    /// @notice Nobody resolved by 48h: credit the clean destination (risk fee → LP fund;
    ///         principal → LP wallet). If the oracle/list already marks the wallet illicit,
    ///         the row is Blocked instead.
    function releaseDefault(uint256 escrowId) external;

    /// @notice Checkpoint 1 for many escrow ids (same rules as `releaseEarly`).
    function batchReleaseEarly(uint256[] calldata escrowIds) external;

    /// @notice Checkpoint 2 for many escrow ids (same on-chain illicit read as `resolveCheckpoint2`).
    function batchResolveCheckpoint2(uint256[] calldata escrowIds) external;

    /// @notice Default release for many escrow ids (same rules as `releaseDefault`).
    function batchReleaseDefault(uint256[] calldata escrowIds) external;

    /// @notice Escrow owner sends a blocked fee to the compliance reserve after at least 7 days.
    ///         Never the LP compensation fund. `FeeRecovered` records destination, amount, and the swap.
    function recoverBlocked(uint256 escrowId) external;

    /// @notice After the full delay (default 90 days), anyone may send an expired blocked fee to the compliance reserve.
    function recoverExpiredBlocked(uint256 escrowId) external;

    /// @notice Read a single escrow record. Restricted to owner or an auditor.
    function getEscrow(uint256 escrowId) external view returns (EscrowRecord memory);

    /// @notice Public digest: wallet is hashed, remaining fields are plaintext.
    function getEscrowPublic(uint256 escrowId)
        external
        view
        returns (
            bytes32 walletHash,
            address token,
            uint256 amount,
            uint64 depositedAt,
            bytes32 swapFingerprint,
            EscrowStatus status,
            uint64 blockedAt,
            EscrowKind kind
        );
}
