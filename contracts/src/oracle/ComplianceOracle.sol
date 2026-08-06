// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IComplianceOracle} from "../interfaces/IComplianceOracle.sol";

/// @title Layer 2 — ComplianceOracle (REAL on-chain storage)
/// @notice Stores keeper-written scores + COA recommended feeBps. Hook only reads; keeper writes.
/// @dev Not a mock: scores persist on-chain. The off-chain COA that *computes* score/fee
///      may still be a TypeScript mock; publishing uses `updateScore` (real tx when RPC is set).
contract ComplianceOracle is IComplianceOracle {
    address public owner;
    mapping(address => bool) public keepers;
    mapping(address => WalletRisk) private _risk;

    error NotOwner();
    error NotKeeper();
    error ScoreOutOfRange();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event KeeperUpdated(address indexed keeper, bool allowed);

    constructor(address owner_) {
        owner = owner_;
        keepers[owner_] = true;
        emit OwnershipTransferred(address(0), owner_);
        emit KeeperUpdated(owner_, true);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (!keepers[msg.sender]) revert NotKeeper();
        _;
    }

    /// @inheritdoc IComplianceOracle
    function getRisk(address wallet) external view returns (WalletRisk memory) {
        return _risk[wallet];
    }

    /// @inheritdoc IComplianceOracle
    function getScore(address wallet) external view returns (uint8) {
        return _risk[wallet].score;
    }

    /// @inheritdoc IComplianceOracle
    function updateScore(
        address wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        uint24 feeBps,
        bytes calldata /* signature */
    ) external onlyKeeper {
        if (score > 100) revert ScoreOutOfRange();
        uint64 ts = uint64(block.timestamp);
        _risk[wallet] = WalletRisk({
            score: score,
            hopDistance: hopDistance,
            origin: origin,
            feeBps: feeBps,
            updatedAt: ts
        });
        emit ScoreUpdated(wallet, score, hopDistance, origin, feeBps, ts);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        keepers[keeper] = allowed;
        emit KeeperUpdated(keeper, allowed);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
