// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";

/// @title Layer 2 — ComplianceOracle (REAL on-chain storage)
/// @notice On-chain behavioral score store (whitepaper §3.2 Layer 2 / §3.5 / §3.8).
///
/// @dev ═══════════════════════════════════════════════════════════════════════
///      WHY THIS STORE EXISTS
///      ═══════════════════════════════════════════════════════════════════════
///
///      beforeSwap must finish in one transaction. It cannot run the off-chain graph
///      (N-hop decay, exploit feeds, typology). So the Oracle Keeper / COA computes
///      off-chain and *publishes* here via `updateScore`. AMLHook only reads.
///
///      Each WalletRisk carries:
///        score        0–100 behavioral risk (feeds RiskPolicy bands)
///        hopDistance  N-hop distance from origin (audit / reporting)
///        origin       contaminated source wallet (e.g. exploit Wallet A)
///        feeBps       keeper-recommended FEE_OVERRIDE fee (COA)
///        updatedAt    publication timestamp — powers §3.8 Mitigations A/B/D
///
///      WHY updatedAt matters:
///        updatedAt == 0  → never written (unknown ≠ clean) → Mitigation A
///        too old         → stale → Mitigation B (with pool activity)
///        older than inflow baseline → Mitigation D can fire (Wallet D)
///
///      Confirmed-clean wallets must be written explicitly: score 0 + non-zero updatedAt.
///
///      Auth: shared AccessManager role `_ORACLE_KEEPER` (not the sanctions writer).
contract ComplianceOracle is AccessManaged, IComplianceOracle {
    mapping(address => WalletRisk) private _risk;

    error ScoreOutOfRange();

    /// @notice Deploys the oracle under an access manager.
    /// @param initialAuthority_ The access manager that decides who may publish scores.
    constructor(address initialAuthority_) AccessManaged(initialAuthority_) {}

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

    /// @inheritdoc IComplianceOracle
    /// @notice Keeper publication of a pre-calculated risk profile (§3.8).
    /// @dev Off-chain engine owns N-hop decay / typology; this call only persists results.
    ///      Setting score 0 with a fresh `updatedAt` marks confirmed-clean (Mitigation A).
    ///      TODO: `signature` is NOT verified. Authorization is AccessManager `_ORACLE_KEEPER`
    ///      only. The bytes argument is reserved for a future attestation scheme and must not
    ///      be treated as cryptographic proof in the current stack.
    ///      Restricted to `_ORACLE_KEEPER` — a compromised key is revoked on the AccessManager.
    function updateScore(
        address wallet,
        uint8 score,
        uint8 hopDistance,
        address origin,
        uint24 feeBps,
        bytes calldata /* signature */
    ) external restricted {
        if (score > 100) revert ScoreOutOfRange();
        uint64 ts = uint64(block.timestamp);
        _risk[wallet] = WalletRisk({
            score: score,
            hopDistance: hopDistance,
            origin: origin,
            feeBps: feeBps,
            updatedAt: ts
        });
        emit ScoreUpdated(wallet, score, hopDistance, origin, feeBps, ts);
    }
}
