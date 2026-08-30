// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";

/// @title Layer 1: SanctionRegistry (REAL on-chain list)
/// @notice Static sanctions screening (whitepaper §3.2 Layer 1 / §3.5 / §4.1 OFAC/SDN).
///
/// @dev `setSanctioned` remains available for immediate emergencies and for the COA's
///      live OFAC SDN writer (exact-address match). Production listings
///      should use the commit-reveal path. Reveal transactions MUST be submitted via a
///      private mempool (Flashbots Protect or equivalent); this contract cannot enforce
///      that on-chain. A public reveal exposes `account` in calldata before inclusion.
///      `revealSanction` is already `restricted` to `_REGISTRY_KEEPER`, so an extra
///      on-chain "trusted relayer" gate would not hide that calldata from a public mempool.
contract SanctionRegistry is AccessManaged, ISanctionRegistry {
    mapping(address => bool) private _sanctioned;

    uint256 public constant MIN_REVEAL_DELAY = 10;
    uint256 public revealDelay = 10;
    mapping(bytes32 => uint256) public commitBlocks;

    error CommitNotFound();
    error RevealTooEarly();
    error CommitAlreadyUsed();
    error RevealDelayTooLow();

    event SanctionCommitted(bytes32 indexed commitHash, uint256 blockNumber);
    event RevealDelayUpdated(uint256 previous, uint256 current);

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

    /// @notice Governor retunes the commit-reveal delay. Floor is `MIN_REVEAL_DELAY` (10 blocks).
    function setRevealDelay(uint256 revealDelay_) external restricted {
        if (revealDelay_ < MIN_REVEAL_DELAY) revert RevealDelayTooLow();
        emit RevealDelayUpdated(revealDelay, revealDelay_);
        revealDelay = revealDelay_;
    }

    /// @notice Step 1: commit to the intent without revealing the address.
    /// @param commitHash keccak256(abi.encode(account, sanctioned, salt))
    /// @dev Salt-reuse note: `revealSanction` deletes the commit entry, so the same
    ///      (account, sanctioned, salt) triple can be re-committed after a reveal.
    ///      Use a unique salt per operation to avoid accidental hash collisions across
    ///      list/delist/re-list sequences.
    function commitSanction(bytes32 commitHash) external restricted {
        if (commitBlocks[commitHash] != 0) revert CommitAlreadyUsed();
        commitBlocks[commitHash] = block.number;
        emit SanctionCommitted(commitHash, block.number);
    }

    /// @notice Step 2: reveal and apply the sanction after `revealDelay` blocks.
    /// @dev Submit this transaction via a private mempool in production (C-02). The
    ///      delay only reduces, it does not eliminate, public-mempool front-running.
    function revealSanction(address account, bool sanctioned, bytes32 salt) external restricted {
        bytes32 h = keccak256(abi.encode(account, sanctioned, salt));
        uint256 committedAt = commitBlocks[h];
        if (committedAt == 0) revert CommitNotFound();
        if (block.number <= committedAt + revealDelay) revert RevealTooEarly();
        delete commitBlocks[h];
        _sanctioned[account] = sanctioned;
        emit SanctionUpdated(account, sanctioned);
    }
}
