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
contract SanctionRegistry is AccessManaged, ISanctionRegistry {
    mapping(address => bool) private _sanctioned;
    mapping(bytes32 => uint256) public commitTimestamps;
    uint256 public constant REVEAL_DELAY = 1;

    event SanctionCommitted(bytes32 indexed commitHash, uint256 blockNumber);

    error UnknownCommit(bytes32 commitHash);
    error RevealTooEarly(uint256 committedAt);

    /// @notice Deploys the registry under an access manager.
    /// @param initialAuthority_ The access manager that decides who may write the list.
    constructor(address initialAuthority_) AccessManaged(initialAuthority_) {}

    /// @inheritdoc ISanctionRegistry
    /// @notice True if `account` is on the static sanctions list (fail-closed for the hook).
    function isSanctioned(address account) external view returns (bool) {
        return _sanctioned[account];
    }

    /// @inheritdoc ISanctionRegistry
    /// @notice Writer-role update for a single address (event-driven OFAC-style writes; §3.8).
    /// @dev Emergency direct write. The preferred production path is commit-reveal
    ///      (`commitSanction` then `revealSanction`) so the sanctioned address is not
    ///      visible in the mempool before the flag is applied.
    function setSanctioned(address account, bool sanctioned) external restricted {
        _sanctioned[account] = sanctioned;
        emit SanctionUpdated(account, sanctioned);
    }

    /// @notice First step of the production sanctions path: commit a hash of (account, sanctioned, salt).
    function commitSanction(bytes32 commitHash) external restricted {
        commitTimestamps[commitHash] = block.number;
        emit SanctionCommitted(commitHash, block.number);
    }

    /// @notice Second step: reveal the committed sanction after `REVEAL_DELAY` blocks.
    function revealSanction(address account, bool sanctioned, bytes32 salt) external restricted {
        bytes32 h = keccak256(abi.encode(account, sanctioned, salt));
        uint256 committedAt = commitTimestamps[h];
        if (committedAt == 0) revert UnknownCommit(h);
        if (block.number <= committedAt + REVEAL_DELAY) revert RevealTooEarly(committedAt);
        _sanctioned[account] = sanctioned;
        emit SanctionUpdated(account, sanctioned);
        delete commitTimestamps[h];
    }
}
