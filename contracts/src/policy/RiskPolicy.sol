// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "../interfaces/IRiskPolicy.sol";
import {HookDecision} from "../libraries/HookDecision.sol";

/// @title Layer 3 — RiskPolicy (REAL on-chain decision mapping)
/// @notice Fixed product bands: 0–30 ALLOW, 31–70 FEE_OVERRIDE, 71–100 REVERT.
/// @dev Not mocked — deployed and called by AmlHook. Fee curve is demo-oriented
///      (punitive/proportional 8% / 3% style via score bands).
contract RiskPolicy is IRiskPolicy {
    uint24 public constant STANDARD_FEE_BPS = 30; // 0.30% — informational; pool applies base fee on ALLOW
    uint24 public constant PUNITIVE_FEE_BPS = 800; // 8.00%  (~1-hop / score ~65)
    uint24 public constant PROPORTIONAL_FEE_BPS = 300; // 3.00% (~2-hop / score ~42)

    /// @inheritdoc IRiskPolicy
    function decide(uint8 score)
        external
        pure
        returns (HookDecision decision, uint24 feeBps)
    {
        if (score >= 71) {
            return (HookDecision.REVERT, 0);
        }
        if (score >= 31) {
            // Split FEE_OVERRIDE band: higher scores → punitive, lower → proportional
            feeBps = score >= 55 ? PUNITIVE_FEE_BPS : PROPORTIONAL_FEE_BPS;
            return (HookDecision.FEE_OVERRIDE, feeBps);
        }
        return (HookDecision.ALLOW, 0);
    }
}
