// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Roles
/// @notice The access manager role ids used across the AML stack.
/// @dev Once authorization moves to a shared `AccessManager`, no contract states who may call it any
///      more. These ids are the single place the deploy script and the tests agree on, so the two
///      cannot drift.
///
///      Ids start at 1 because the manager reserves both ends: 0 is `ADMIN_ROLE` and
///      `type(uint64).max` is `PUBLIC_ROLE`, which every address holds. Granting either by accident
///      would open a function to everyone, so nothing here may use them.
///
///      The roles are kept apart on purpose. Sanctions designations and behavioral scores are
///      different jobs on different infrastructure, and a single shared keeper role would let either
///      key write the other's data. The same reasoning separates the two keepers from the governor:
///      the keepers write data all day on automated infrastructure, while the governor changes which
///      contracts the hook trusts and how it retunes its own thresholds, and should move rarely, under
///      a delay, from a key held by people.
///
///      `FeeEscrow` is not wired to these roles. It keeps its own owner/keeper/depositor pattern for
///      now; folding it into this manager is a separate decision, not part of this migration.
library Roles {
  /// @notice Writes the sanctions list: `setSanctioned` on the sanction registry
  uint64 internal constant _REGISTRY_KEEPER = 1;

  /// @notice Publishes behavioral risk profiles: `updateScore` on the compliance oracle
  uint64 internal constant _ORACLE_KEEPER = 2;

  /// @notice Retunes the hook's thresholds and manages its trusted-router list
  /// @dev The only role that can change how the hook behaves. It cannot touch the swap path itself,
  ///      which is fixed in the hook's bytecode. This is the role to put an execution delay on: the
  ///      manager supports one natively, and none of these calls is urgent
  uint64 internal constant _HOOK_GOVERNOR = 3;
}
