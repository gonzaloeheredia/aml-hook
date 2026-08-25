// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Layer 2 — on-chain behavioral score store
/// @notice The oracle keeper publishes a Compliance Officer Agent score; AMLHook reads
///         it at beforeSwap (whitepaper §3.2 Layer 2 / §3.5 / §3.8). The hook never
///         writes scores and never calls the agent.
/// @dev Clocks (UHI10 demo): the COA writes on transfer / swap / seed (waits for Claude
///      or the skill interpreter). A 3-minute keeper tick republishes the last score
///      without calling the agent so `updatedAt` stays fresh. Floor B arms if that stamp
///      is older than `stalenessThreshold` (default 5 minutes). If the agent never
///      published (`updatedAt == 0`), Floor A applies instead of B.
interface IComplianceOracle {
    /// @notice Per-wallet risk snapshot emitted by the COA and published by the keeper.
    /// @dev `hopDistance` / `origin` support N-hop decay from the UHI10 use-case skill;
    ///      `updatedAt` distinguishes never-written (0) from confirmed-clean (score 0, ts ≠ 0).
    struct WalletRisk {
        uint8 score; // 0–100 — ternary bands in RiskPolicy (§3.3)
        uint8 hopDistance; // 0 = origin / unknown; N-hop from contamination source
        address origin; // contamination origin wallet (address(0) if clean)
        uint24 feeBps; // COA recommended fee (bps), published by the keeper; used on FEE_OVERRIDE
        uint64 updatedAt; // unix timestamp of last keeper publish (Mitigations A/B/D). 0 = never written.
    }

    event ScoreUpdated(
        address indexed wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        uint24 feeBps,
        uint64 updatedAt
    );

    /// @notice Returns the stored risk profile (defaults to clean / score 0 if unset).
    /// @dev Unset means `updatedAt == 0` — Mitigation A elevates that path; confirmed clean
    ///      requires an explicit keeper publish of score 0 with non-zero `updatedAt`.
    function getRisk(address wallet) external view returns (WalletRisk memory);

    /// @notice Convenience: score only (0–100).
    function getScore(address wallet) external view returns (uint8);

    /// @notice Keeper publish of a COA-emitted risk profile, attested by the registered attestor.
    /// @dev `signature` is ECDSA over
    ///      keccak256(abi.encode(wallet, score, hopDistance, origin, feeBps, updatedAt, chainId, nonce))
    ///      as an Ethereum signed message. `updatedAt` is `block.timestamp` at inclusion.
    ///      `nonce` is `updateNonce[wallet]` at sign time.
    function updateScore(
        address wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        uint24 feeBps,
        bytes calldata signature
    ) external;
}
