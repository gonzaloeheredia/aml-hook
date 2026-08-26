// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Ledged compliance fund — two accounts, never mixed
/// @notice Holds seized LP principal and recovered illicit risk fees for the authority.
///         The LP compensation fund is a different address and is not this contract.
interface IComplianceTreasury {
    /// @notice Internal ledger. `LP_PRINCIPAL` is capital taken on a blocked LP exit.
    ///         `ILLICIT_RISK_FEE` is only a FeeEscrow recovery after the oracle/list confirms.
    enum Account {
        LP_PRINCIPAL,
        ILLICIT_RISK_FEE
    }

    /// @notice ERC-20 booked on `account` (must equal the token balance sum of both accounts).
    function balances(Account account, address token) external view returns (uint256);

    /// @notice Hook posts seized LP principal. Pulls `amount` of `token` from the caller.
    function creditPrincipal(
        address wallet,
        address token,
        uint256 amount,
        uint256 seizeId,
        bytes32 poolId,
        bytes32 positionKey
    ) external;

    /// @notice FeeEscrow notifies a recovery already transferred to this contract.
    function recordIllicitFee(
        address wallet,
        address token,
        uint256 amount,
        uint256 escrowId,
        bytes32 fingerprint
    ) external;
}
