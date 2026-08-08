// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Layer 2 — on-chain behavioral score store
/// @notice Written by the off-chain Oracle Keeper; read by AMLHook at beforeSwap
///         (whitepaper §3.2 Layer 2 / §3.5 / §3.8). Hook never writes scores on-chain.
interface IComplianceOracle {
    /// @notice Per-wallet risk snapshot published by the keeper.
    /// @dev `hopDistance` / `origin` support N-hop decay attribution from the use case;
    ///      `updatedAt` distinguishes never-written (0) from confirmed-clean (score 0, ts ≠ 0).
    struct WalletRisk {
        uint8 score; // 0–100 — ternary bands in RiskPolicy (§3.3)
        uint8 hopDistance; // 0 = origin / unknown; N-hop from contamination source
        address origin; // contamination origin wallet (address(0) if clean)
        uint24 feeBps; // COA recommended fee (bps); used on FEE_OVERRIDE
        uint64 updatedAt; // unix timestamp of last keeper write (Mitigations A/B/D)
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
    ///      requires an explicit keeper write of score 0 with non-zero `updatedAt`.
    function getRisk(address wallet) external view returns (WalletRisk memory);

    /// @notice Convenience: score only (0–100).
    function getScore(address wallet) external view returns (uint8);

    /// @notice Keeper write of pre-calculated score + optional recommended fee (§3.8).
    /// @dev `signature` reserved for future attestation; N-hop / typology math stays off-chain.
    function updateScore(
        address wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        uint24 feeBps,
        bytes calldata signature
    ) external;
}
