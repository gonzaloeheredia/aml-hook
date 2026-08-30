// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Ledged compliance fund: two accounts, never mixed
/// @notice Holds seized LP principal and recovered illicit risk fees for the authority.
///         The LP compensation vault is a different address and is not this contract.
interface IComplianceTreasury {
    /// @notice Internal ledger. `LP_PRINCIPAL` is seized LP capital after a confirmed-illicit
    ///         FeeEscrow recover (48h hold first). `ILLICIT_RISK_FEE` is only a risk-fee recover
    ///         after the oracle/list confirms.
    enum Account {
        LP_PRINCIPAL,
        ILLICIT_RISK_FEE
    }

    /// @notice Lifecycle of one delayed payout to an allowlisted authority destination.
    enum PayoutStatus {
        Pending,
        Executed,
        Cancelled
    }

    /// @notice One proposed outflow. Tokens stay booked until execute or cancel.
    struct Payout {
        Account account;
        address token;
        uint256 amount;
        address to;
        bytes32 fileHash;
        string memo;
        uint64 proposedAt;
        uint256 escrowId;
        bytes32 fingerprint;
        PayoutStatus status;
    }

    /// @notice ERC-20 booked on `account` (must equal the token balance sum of both accounts
    ///         minus tokens reserved in pending payouts).
    function balances(Account account, address token) external view returns (uint256);

    /// @notice Optional hook credit of seized LP principal (pulls `token`). Production seize
    ///         holds 48h in FeeEscrow; recover then calls `recordSeizedPrincipal`.
    function creditPrincipal(
        address wallet,
        address token,
        uint256 amount,
        uint256 seizeId,
        bytes32 poolId,
        bytes32 positionKey
    ) external;

    /// @notice FeeEscrow notifies a recovered LP-principal row already transferred to this contract.
    function recordSeizedPrincipal(
        address wallet,
        address token,
        uint256 amount,
        uint256 escrowId,
        bytes32 fingerprint
    ) external;

    /// @notice FeeEscrow notifies a recovery already transferred to this contract.
    function recordIllicitFee(
        address wallet,
        address token,
        uint256 amount,
        uint256 escrowId,
        bytes32 fingerprint
    ) external;

    /// @notice Owner proposes an allowlisted payout. Executes after `payoutDelay`.
    function proposePayout(
        Account account,
        address token,
        uint256 amount,
        address to,
        bytes32 fileHash,
        string calldata memo,
        uint256 escrowId,
        bytes32 fingerprint
    ) external returns (uint256 payoutId);

    /// @notice Execute a pending payout after the delay. Debits only that ledger account.
    function executePayout(uint256 payoutId) external;

    /// @notice Cancel a pending payout and release the reserved amount.
    function cancelPayout(uint256 payoutId) external;
}
