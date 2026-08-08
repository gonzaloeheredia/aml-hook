// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISanctionRegistry} from "../interfaces/ISanctionRegistry.sol";

/// @title Layer 1 — SanctionRegistry (REAL on-chain list)
/// @notice Static sanctions screening (whitepaper §3.2 Layer 1 / §3.5 / §4.1 OFAC/SDN):
///         fast on-chain lookup with no oracle dependency at execution time.
/// @dev Minimal on-chain storage (not a stub). Population of OFAC / mirrors is off-chain /
///      admin for now — the registry itself and `isSanctioned` reads are live contracts.
///      A hit forces unconditional REVERT in beforeSwap before Layer 2 or Layer 3 run.
contract SanctionRegistry is ISanctionRegistry {
    address public owner;
    mapping(address => bool) private _sanctioned;

    error NotOwner();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SanctionUpdated(address indexed account, bool sanctioned);

    constructor(address owner_) {
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @inheritdoc ISanctionRegistry
    /// @notice True if `account` is on the static sanctions list (fail-closed for the hook).
    function isSanctioned(address account) external view returns (bool) {
        return _sanctioned[account];
    }

    /// @inheritdoc ISanctionRegistry
    /// @notice Owner/ops update for a single address (event-driven OFAC-style writes; §3.8).
    function setSanctioned(address account, bool sanctioned) external onlyOwner {
        _sanctioned[account] = sanctioned;
        emit SanctionUpdated(account, sanctioned);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
