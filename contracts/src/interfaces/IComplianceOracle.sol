// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Layer 2 — on-chain behavioral score store
/// @notice Written by the off-chain Oracle Keeper; read by AMLHook at beforeSwap.
interface IComplianceOracle {
    struct WalletRisk {
        uint8 score; // 0–100
        uint8 hopDistance; // 0 = origin / unknown; N-hop from contamination source
        address origin; // contamination origin wallet (address(0) if clean)
        uint64 updatedAt; // unix timestamp of last keeper write
    }

    event ScoreUpdated(
        address indexed wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        uint64 updatedAt
    );

    /// @notice Returns the stored risk profile (defaults to clean / score 0 if unset).
    function getRisk(address wallet) external view returns (WalletRisk memory);

    /// @notice Convenience: score only (0–100).
    function getScore(address wallet) external view returns (uint8);

    /// @notice Keeper write. `signature` reserved for EIP-712 / oracle attestation (may be empty in mock).
    function updateScore(
        address wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        bytes calldata signature
    ) external;
}
