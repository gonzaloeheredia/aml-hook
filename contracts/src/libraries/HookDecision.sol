// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Ternary AML Hook output (product bands 0–30 / 31–70 / 71–100).
enum HookDecision {
    ALLOW,
    FEE_OVERRIDE,
    REVERT
}
