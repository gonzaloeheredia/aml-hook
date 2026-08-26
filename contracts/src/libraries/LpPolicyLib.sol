// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRiskPolicy} from "../interfaces/policies/IRiskPolicy.sol";
import {HookDecision} from "./HookDecision.sol";
import {RiskPolicyLib} from "./RiskPolicyLib.sol";

/// @title LpPolicyLib — liquidity-only Layer 3 (not a swap)
/// @notice Maps list-cleared LP subjects to ALLOW / FEE_OVERRIDE / REVERT.
/// @dev Independent of `RiskPolicyLib.decide` for a **known** score: Floor B (stale) does
///      not arm, and Mitigation D does not apply. Never-scored adds reuse the swap Floor A
///      + C + D + pool-impact tree (`RiskPolicyLib.decide`) so the USD cuts stay in lockstep.
///      The hook never calls the agent.
library LpPolicyLib {
    /// @notice LP add decision. Call after Layer 1. Score ≥ 71 is REVERT.
    /// @dev Known 0–30 → ALLOW (0 extra), even if the oracle row is stale.
    ///      Known 31–70 → FEE_OVERRIDE from the published score / COA fee (3% / 8%).
    ///      Never-scored → same A/C/D/pool-impact mapping as a never-scored swap.
    function decide(IRiskPolicy.DecisionInput memory in_)
        internal
        pure
        returns (IRiskPolicy.DecisionResult memory r)
    {
        if (in_.neverScored || in_.score >= 71) {
            return RiskPolicyLib.decide(in_);
        }
        if (in_.score >= 31) {
            r.decision = HookDecision.FEE_OVERRIDE;
            r.feeBps = RiskPolicyLib.overrideFeeBps(in_);
            return r;
        }
        r.decision = HookDecision.ALLOW;
    }
}
