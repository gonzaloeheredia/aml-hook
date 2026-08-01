// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISanctionRegistry} from "../interfaces/ISanctionRegistry.sol";

/// @title Layer 1 — SanctionRegistry (REAL on-chain list)
/// @dev Minimal on-chain storage (not a stub). Population of OFAC / mirrors is off-chain /
///      admin for now — the registry itself and `isSanctioned` reads are live contracts.
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
    function isSanctioned(address account) external view returns (bool) {
        return _sanctioned[account];
    }

    /// @inheritdoc ISanctionRegistry
    function setSanctioned(address account, bool sanctioned) external onlyOwner {
        _sanctioned[account] = sanctioned;
        emit SanctionUpdated(account, sanctioned);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
