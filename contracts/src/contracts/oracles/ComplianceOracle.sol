// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";

/// @title Layer 2 — ComplianceOracle (REAL on-chain storage)
/// @notice On-chain behavioral score store (whitepaper §3.2 Layer 2 / §3.5 / §3.8):
///         the off-chain Oracle Keeper publishes scores; AMLHook only reads at beforeSwap.
/// @dev Not a mock: scores persist on-chain. The off-chain engine that *computes* score/fee
///      (graph, N-hop decay, exploit feeds) may still be TypeScript; publishing uses `updateScore`.
///      `updatedAt` enables Mitigations A/B/D (never-written vs confirmed-clean; staleness; inflow).
///      Hook never writes this store — only the keeper does between swaps.
///
///      Authorization is delegated to the shared `AccessManager` rather than an owner of this
///      contract's own, so a compromised keeper key is revoked in one place regardless of how many
///      contracts it could otherwise reach. `updateScore` is meant for the oracle-keeper role,
///      deliberately distinct from the role that writes the sanctions list.
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
    /// @dev Off-chain engine owns N-hop decay / typology scoring; this call only persists results.
    ///      Setting score 0 with non-zero `updatedAt` marks a confirmed-clean wallet (Mitigation A).
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
