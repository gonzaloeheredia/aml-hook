// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Ternary AML Hook output (whitepaper §3.3) — the product differentiator vs binary KYC.
/// @dev ALLOW (0–30): standard pool fee. FEE_OVERRIDE (31–70): differential fee / EDD friction.
///      REVERT (71–100 or L1 sanction hit): unconditional block, no fee path.
enum HookDecision {
    ALLOW,
    FEE_OVERRIDE,
    REVERT
}
