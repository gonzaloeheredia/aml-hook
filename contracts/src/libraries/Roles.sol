// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Roles
/// @notice AccessManager role ids for the AML stack (whitepaper governance model).
///
/// @dev ═══════════════════════════════════════════════════════════════════════
///      WHY A SHARED ACCESSMANAGER + SPLIT ROLES
///      ═══════════════════════════════════════════════════════════════════════
///
///      After dropping per-contract `owner`/`onlyOwner`, no contract stores "who may
///      call me". That decision lives in one OpenZeppelin AccessManager. These ids
///      are the single place Deploy.sol and the tests agree on — so they cannot drift.
///
///      Ids start at 1 because the manager reserves:
///        0                 = ADMIN_ROLE
///        type(uint64).max  = PUBLIC_ROLE (everyone)
///      Using either by accident would open a function too widely.
///
///      WHY FOUR ROLES (not one keeper):
///        _REGISTRY_KEEPER      — OFAC-style list writes (designation pipeline)
///        _ORACLE_KEEPER        — publishes COA scores (`ComplianceOracle.updateScore`)
///        _HOOK_GOVERNOR        — trusted routers + operational thresholds (rare, human)
///        _COMPLIANCE_OFFICER   — FATF/policy knobs (USD floors, floor fees, pool-impact)
///      Different jobs, different infrastructure. One shared key would let a
///      compromised scorer rewrite sanctions (or vice versa). The governor is
///      separate again: keepers write data continuously; governors retune trust.
///      Policy percentages and dollar floors sit on their own role so a router
///      change cannot silently rewrite the FATF cuts (48h execution delay on grant).
///
///      FeeEscrow is NOT on these roles — it keeps its own owner/keeper/depositor
///      model (settlement path is a different authorization shape; see FeeEscrow).
library Roles {
    /// @notice Writes the sanctions list: `SanctionRegistry.setSanctioned`
    uint64 internal constant _REGISTRY_KEEPER = 1;

    /// @notice Publishes COA-emitted risk profiles: `ComplianceOracle.updateScore`
    /// @dev Does not compute the score. The agent emits; this role submits the attested tx.
    uint64 internal constant _ORACLE_KEEPER = 2;

    /// @notice Retunes operational hook thresholds and trusted-router list
    /// @dev Cannot touch the swap path itself (fixed in AmlHook bytecode).
    ///      Prefer putting an execution delay on this role in production.
    uint64 internal constant _HOOK_GOVERNOR = 3;

    /// @notice Retunes policy knobs: USD floors, floor fees, pool-impact cut
    /// @dev Propose is immediate (membership check). Apply is `restricted` so the
    ///      AccessManager grant delay (48 hours in Deploy) gates confirmation.
    ///      Cannot write scores, sanctions, or trusted routers.
    uint64 internal constant _COMPLIANCE_OFFICER = 4;
}
