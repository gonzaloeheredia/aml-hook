// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";

/// @title Layer 2 — ComplianceOracle (REAL on-chain storage)
/// @notice On-chain store of Compliance Officer Agent scores (whitepaper §3.2 Layer 2 / §3.5 / §3.8).
///
/// @dev ═══════════════════════════════════════════════════════════════════════
///      WHY THIS STORE EXISTS
///      ═══════════════════════════════════════════════════════════════════════
///
///      beforeSwap must finish in one transaction. It cannot run the off-chain agent
///      (N-hop decay, exploit facts, typology, Opinion). The Compliance Officer Agent
///      emits `finalScore` + `recommendedFeeBps` off-chain. `_ORACLE_KEEPER` *publishes*
///      that row here via `updateScore`. AMLHook only reads. The hook never calls the agent.
///
///      Demo clocks: event-driven COA write (transfer / swap / seed) waits on the agent.
///      A 3-minute heartbeat then stamps the last score (no Claude) so Floor B (5-minute
///      `stalenessThreshold`) does not fire on a stable wallet. If the agent is down and
///      there is no last score, Floor A (never-written) applies. If there is a last score
///      but both the agent and the tick are slower than 5 minutes, Floor B applies.
///
///      Auth: `_ORACLE_KEEPER` submits the tx; a distinct `attestor` ECDSA-signs the
///      payload (C-01). `_HOOK_GOVERNOR` rotates the attestor.
contract ComplianceOracle is AccessManaged, IComplianceOracle {
    mapping(address => WalletRisk) private _risk;

    /// @dev Cap per wallet per `updateWindow`. 24 fits a 5-minute freshness write plus a few
    ///      real tier changes (whitepaper §8.4). Governor retunes via `setRateLimit`.
    uint256 public maxUpdatesPerWindow = 24;
    uint64 public updateWindow = 1 hours;

    /// @notice ECDSA attestor for `updateScore` payloads. Distinct from `_ORACLE_KEEPER`.
    address public attestor;

    error ScoreOutOfRange();
    error UpdateRateLimited(address wallet);
    error InvalidRateLimit();
    error InvalidAttestation();
    error ZeroAddress();

    event RateLimitUpdated(uint256 maxUpdates, uint64 window);
    event AttestorUpdated(address indexed previous, address indexed current);

    /// @dev Sliding window of recent `updateScore` timestamps per wallet (H-05).
    mapping(address => uint64[]) private _updateTimestamps;

    /// @notice Per-wallet nonce incremented on every successful `updateScore` (M-03 replay protection).
    /// @dev Included in `attestationHash` so each keeper submission commits to one nonce slot.
    ///      Replayed signatures with an old nonce will produce a different hash and fail ECDSA recovery.
    mapping(address => uint256) public updateNonce;

    /// @notice Deploys the oracle under an access manager.
    /// @param initialAuthority_ The access manager that decides who may publish scores.
    /// @param attestor_ Initial ECDSA attestor (non-zero).
    constructor(address initialAuthority_, address attestor_) AccessManaged(initialAuthority_) {
        if (attestor_ == address(0)) revert ZeroAddress();
        attestor = attestor_;
        emit AttestorUpdated(address(0), attestor_);
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

    /// @notice Digest the attestor must sign (Ethereum signed message of this hash).
    /// @dev Binds the full published snapshot: hop/origin cannot be swapped under a score-only signature.
    ///      M-03 fix: `updateNonce[wallet]` is mixed in so each attestation commits to exactly one
    ///      call slot. After `updateScore` increments the nonce, all previously-signed payloads
    ///      for this wallet are invalidated — a keeper cannot replay a prior signature to
    ///      restore an earlier (lower) score. Keepers must read the current nonce before signing.
    function attestationHash(
        address wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        uint24 feeBps,
        uint64 updatedAt
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(wallet, score, hopDistance, origin, feeBps, updatedAt, block.chainid, updateNonce[wallet])
        );
    }

    /// @inheritdoc IComplianceOracle
    /// @notice Keeper publication of a COA-emitted risk profile (§3.8).
    /// @dev The agent owns N-hop decay / typology / fee. This call only persists results.
    ///      Setting score 0 with a fresh `updatedAt` marks confirmed-clean (Mitigation A).
    ///      `signature` must be ECDSA from `attestor` over `attestationHash` (wallet, score,
    ///      hopDistance, origin, feeBps, updatedAt=block.timestamp, chainid). Restricted to
    ///      `_ORACLE_KEEPER`.
    ///
    ///      H-01: score updates that move a wallet into the REVERT band (71–100) MUST be
    ///      submitted via a private mempool (Flashbots Protect or equivalent). The contract
    ///      cannot enforce that on-chain; a public listing can be front-run by the wallet.
    function updateScore(
        address wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        uint24 feeBps,
        bytes calldata signature
    ) external restricted {
        uint64 ts = uint64(block.timestamp);
        _verifyAttestation(wallet, score, hopDistance, origin, feeBps, ts, signature);
        // M-03: increment nonce AFTER signature verification so the consumed nonce matches
        // exactly what the attestor signed, but BEFORE writing state so any re-entry would fail.
        unchecked {
            updateNonce[wallet] += 1;
        }
        _enforceSlidingWindow(wallet);

        if (score > 100) revert ScoreOutOfRange();

        _risk[wallet] = WalletRisk({
            score: score,
            hopDistance: hopDistance,
            origin: origin,
            feeBps: feeBps,
            updatedAt: ts
        });
        emit ScoreUpdated(wallet, score, hopDistance, origin, feeBps, ts);
    }

    /// @notice Governor retunes the per-wallet `updateScore` sliding-window rate limit.
    function setRateLimit(uint256 maxUpdates, uint64 window) external restricted {
        if (maxUpdates == 0 || window == 0) revert InvalidRateLimit();
        maxUpdatesPerWindow = maxUpdates;
        updateWindow = window;
        emit RateLimitUpdated(maxUpdates, window);
    }

    /// @notice Governor rotates the ECDSA attestor (C-01). Restricted to `_HOOK_GOVERNOR`.
    function setAttestor(address attestor_) external restricted {
        if (attestor_ == address(0)) revert ZeroAddress();
        emit AttestorUpdated(attestor, attestor_);
        attestor = attestor_;
    }

    /// @dev Recover the ECDSA signer over `attestationHash` and require it equals `attestor`.
    function _verifyAttestation(
        address wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        uint24 feeBps,
        uint64 updatedAt,
        bytes calldata signature
    ) private view {
        if (signature.length != 65) revert InvalidAttestation();
        bytes32 hash = attestationHash(wallet, score, hopDistance, origin, feeBps, updatedAt);
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        address signer = _recoverSigner(ethSigned, signature);
        if (signer == address(0) || signer != attestor) revert InvalidAttestation();
    }

    /// @dev ECDSA recover of `ethSigned` from a 65-byte compact signature in calldata.
    function _recoverSigner(bytes32 ethSigned, bytes calldata signature) private pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        return ecrecover(ethSigned, v, r, s);
    }

    /// @dev H-05: at most `maxUpdatesPerWindow` updates whose timestamps fall in
    ///      `(now - updateWindow, now]`. Oldest samples outside the window are dropped.
    ///      The compaction loop is O(n) in the number of retained samples (bounded by
    ///      `maxUpdatesPerWindow`, default 24). A ring-buffer would reduce this to O(1)
    ///      but the current bound keeps gas predictable for all realistic keeper cadences.
    function _enforceSlidingWindow(address wallet) private {
        uint64[] storage stamps = _updateTimestamps[wallet];
        uint256 cutoff =
            block.timestamp > uint256(updateWindow) ? block.timestamp - uint256(updateWindow) : 0;

        uint256 keepFrom;
        while (keepFrom < stamps.length && uint256(stamps[keepFrom]) <= cutoff) {
            ++keepFrom;
        }
        if (keepFrom > 0) {
            uint256 remaining = stamps.length - keepFrom;
            for (uint256 i; i < remaining; ++i) {
                stamps[i] = stamps[keepFrom + i];
            }
            for (uint256 j; j < keepFrom; ++j) {
                stamps.pop();
            }
        }

        if (stamps.length >= maxUpdatesPerWindow) revert UpdateRateLimited(wallet);
        stamps.push(uint64(block.timestamp));
    }
}
