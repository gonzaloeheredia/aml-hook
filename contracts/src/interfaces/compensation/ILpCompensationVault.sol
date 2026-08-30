// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Retroactive LP compensation vault (whitepaper §8.3)
/// @notice Receives clean FeeEscrow risk-fee releases. LPs claim per closed epoch
///         against a merkle root of shares at the risk-assumption blocks.
interface ILpCompensationVault {
    /// @notice Book unaccounted ERC-20 sitting on this contract into the open epoch.
    function accrue(address token) external;

    /// @notice Book a released FeeEscrow RiskFee row (id must not have been accrued).
    function accrueFromEscrow(uint256 escrowId) external;

    /// @notice Close the open epoch with a merkle root of (account, token, amount) leaves.
    function closeEpoch(bytes32 merkleRoot, uint64 endBlock) external;

    /// @notice Permissionless claim for `account` if the proof is valid and the wallet is not illicit.
    function claim(
        uint256 epoch,
        address account,
        address token,
        uint256 amount,
        bytes32[] calldata proof
    ) external;

    /// @notice After the claim window, roll unclaimed pot into the open epoch.
    function recycleUnclaimed(uint256 epoch, address token) external;

    /// @notice Open epoch id (accruals land here until `closeEpoch`).
    function epochId() external view returns (uint256);
}
