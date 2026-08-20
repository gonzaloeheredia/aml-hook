// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";

/// @title Layer 1 — SanctionRegistry (REAL on-chain list)
/// @notice Static sanctions screening (whitepaper §3.2 Layer 1 / §3.5 / §4.1 OFAC/SDN).
///
/// @dev ═══════════════════════════════════════════════════════════════════════
///      WHY A SEPARATE LAYER BEFORE THE SCORE
///      ═══════════════════════════════════════════════════════════════════════
///
///      Some obligations are objective and binary (e.g. OFAC/SDN match). Those must
///      REVERT immediately — no FEE_OVERRIDE discretion, no behavioral score read.
///      That is why AMLHook checks this registry *first* in beforeSwap.
///
///      Population of the list is off-chain / ops (event-driven list updates). This
///      contract is the live on-chain lookup with no oracle dependency at swap time.
///
///      Auth: shared AccessManager role `_REGISTRY_KEEPER`, deliberately distinct from
///      `_ORACLE_KEEPER`. A sanctions pipeline key must not be able to publish scores,
///      and vice versa. Until wired, `restricted` stays admin-only (fail closed).
///
///      Delisting uses the same call with `sanctioned = false`: a sanction blocks an
///      account; it does not seize funds from it (FeeEscrow confiscation is separate).
///      `setSanctioned` remains available for immediate emergencies. Production listings
///      should use the two-block commit-reveal path to reduce mempool front-running.
contract SanctionRegistry is AccessManaged, ISanctionRegistry {
    mapping(address => bool) private _sanctioned;

    uint256 public constant REVEAL_DELAY = 1;
    mapping(bytes32 => uint256) public commitBlocks;

    error CommitNotFound();
    error RevealTooEarly();
    error CommitAlreadyUsed();

    event SanctionCommitted(bytes32 indexed commitHash, uint256 blockNumber);

    /// @notice Deploys the registry under an access manager.
    /// @param initialAuthority_ The access manager that decides who may write the list.
    constructor(address initialAuthority_) AccessManaged(initialAuthority_) {}

    /// @inheritdoc ISanctionRegistry
    /// @notice True if `account` is on the static sanctions list (fail-closed for the hook).
    function isSanctioned(address account) external view returns (bool) {
        return _sanctioned[account];
    }

    /// @inheritdoc ISanctionRegistry
    /// @notice Immediate write for emergencies. Production listings should use commit-reveal.
    function setSanctioned(address account, bool sanctioned) external restricted {
        _sanctioned[account] = sanctioned;
        emit SanctionUpdated(account, sanctioned);
    }

    /// @notice Paso 1: comprometer la intencion sin revelar la direccion.
    /// @param commitHash keccak256(abi.encode(account, sanctioned, salt))
    function commitSanction(bytes32 commitHash) external restricted {
        if (commitBlocks[commitHash] != 0) revert CommitAlreadyUsed();
        commitBlocks[commitHash] = block.number;
        emit SanctionCommitted(commitHash, block.number);
    }

    /// @notice Paso 2: revelar y aplicar la sancion despues de REVEAL_DELAY bloques.
    function revealSanction(address account, bool sanctioned, bytes32 salt) external restricted {
        bytes32 h = keccak256(abi.encode(account, sanctioned, salt));
        uint256 committedAt = commitBlocks[h];
        if (committedAt == 0) revert CommitNotFound();
        if (block.number <= committedAt + REVEAL_DELAY) revert RevealTooEarly();
        delete commitBlocks[h];
        _sanctioned[account] = sanctioned;
        emit SanctionUpdated(account, sanctioned);
    }
}
