// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";

/// @title Layer 1 — SanctionRegistry (REAL on-chain list)
/// @notice Static sanctions screening (whitepaper §3.2 Layer 1 / §3.5 / §4.1 OFAC/SDN):
///         fast on-chain lookup with no oracle dependency at execution time.
/// @dev Minimal on-chain storage (not a stub). Population of OFAC / mirrors is off-chain /
///      admin for now — the registry itself and `isSanctioned` reads are live contracts.
///      A hit forces unconditional REVERT in beforeSwap before Layer 2 or Layer 3 run.
///
///      Authorization is delegated to the same `AccessManager` the oracle and the hook answer to,
///      instead of an owner of this contract's own. `setSanctioned` is meant for a sanctions-writer
///      role held by the designation pipeline, deliberately distinct from the role that publishes
///      behavioral scores: the two are different jobs on different infrastructure, and a shared key
///      would let either one write the other's data. Until the manager is configured, the function
///      stays admin-only, which is the safe direction for a missing configuration.
contract SanctionRegistry is AccessManaged, ISanctionRegistry {
    mapping(address => bool) private _sanctioned;

    /// @notice Deploys the registry under an access manager.
    /// @param initialAuthority_ The access manager that decides who may write the list.
    constructor(address initialAuthority_) AccessManaged(initialAuthority_) {}

    /// @inheritdoc ISanctionRegistry
    /// @notice True if `account` is on the static sanctions list (fail-closed for the hook).
    function isSanctioned(address account) external view returns (bool) {
        return _sanctioned[account];
    }

    /// @inheritdoc ISanctionRegistry
    /// @notice Writer role update for a single address (event-driven OFAC-style writes; §3.8).
    /// @dev Delisting is the same call with `sanctioned = false`: a sanction blocks an account,
    ///      it does not seize from it.
    function setSanctioned(address account, bool sanctioned) external restricted {
        _sanctioned[account] = sanctioned;
        emit SanctionUpdated(account, sanctioned);
    }
}
