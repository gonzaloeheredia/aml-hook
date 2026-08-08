// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IComplianceOracle} from "../interfaces/IComplianceOracle.sol";

/// @title Layer 2 — ComplianceOracle (REAL on-chain storage)
/// @notice On-chain behavioral score store (whitepaper §3.2 Layer 2 / §3.5 / §3.8):
///         the off-chain Oracle Keeper publishes scores; AMLHook only reads at beforeSwap.
/// @dev Not a mock: scores persist on-chain. The off-chain engine that *computes* score/fee
///      (graph, N-hop decay, exploit feeds) may still be TypeScript; publishing uses `updateScore`.
///      `updatedAt` enables Mitigations A/B/D (never-written vs confirmed-clean; staleness; inflow).
///      Hook never writes this store — only the keeper does between swaps.
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
    /// @notice Full WalletRisk snapshot for beforeSwap (score, hop metadata, feeBps, updatedAt).
    function getRisk(address wallet) external view returns (WalletRisk memory) {
        return _risk[wallet];
    }

    /// @inheritdoc IComplianceOracle
    /// @notice Convenience read of the 0–100 behavioral score only.
    function getScore(address wallet) external view returns (uint8) {
        return _risk[wallet].score;
    }

    /// @inheritdoc IComplianceOracle
    /// @notice Keeper publication of a pre-calculated risk profile (§3.8).
    /// @dev Off-chain engine owns N-hop decay / typology scoring; this call only persists results.
    ///      Prefer writing when the new score would change the hook's decision tier (gas-efficient).
    ///      Setting score 0 with non-zero `updatedAt` marks a confirmed-clean wallet (Mitigation A).
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

    /// @notice Grant or revoke keeper write rights for `updateScore`.
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        keepers[keeper] = allowed;
        emit KeeperUpdated(keeper, allowed);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
