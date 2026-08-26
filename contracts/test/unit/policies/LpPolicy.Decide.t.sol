// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LpPolicy} from "contracts/policies/LpPolicy.sol";
import {IRiskPolicy} from "interfaces/policies/IRiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {LpPolicyLib} from "libraries/LpPolicyLib.sol";
import {RiskPolicyLib} from "libraries/RiskPolicyLib.sol";
import {HelpersCore} from "test/utils/HelpersCore.t.sol";

/// @notice LP Layer 3: known score ignores Floor B; never-scored matches swap A/C/D.
contract UnitLpPolicyDecideTest is HelpersCore {
    LpPolicy lpPolicy;

    function setUp() public {
        lpPolicy = new LpPolicy();
    }

    function test_KnownCleanIsAllowEvenIfStale() external view {
        IRiskPolicy.DecisionInput memory i = _in(0, 800, true, 0);
        IRiskPolicy.DecisionResult memory lp = lpPolicy.decide(i);
        IRiskPolicy.DecisionResult memory swap = RiskPolicyLib.decide(i);
        assertEq(uint8(lp.decision), uint8(HookDecision.ALLOW));
        assertEq(lp.feeBps, 0);
        assertEq(uint8(swap.decision), uint8(HookDecision.FEE_OVERRIDE));
    }

    function test_KnownMediumUsesScoreNotUsd() external view {
        IRiskPolicy.DecisionInput memory i = _usd(42, 300, false, 0, false, 20_000e8, 0, 1_000e8, 15_000e8);
        IRiskPolicy.DecisionResult memory r = lpPolicy.decide(i);
        assertEq(uint8(r.decision), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(r.feeBps, 300);
    }

    function test_NeverScoredMatchesSwapFloorA() external view {
        IRiskPolicy.DecisionInput memory i = _usd(0, 0, false, 0, true, 500e8, 0, 1_000e8, 15_000e8);
        IRiskPolicy.DecisionResult memory lp = LpPolicyLib.decide(i);
        IRiskPolicy.DecisionResult memory swap = RiskPolicyLib.decide(i);
        assertEq(uint8(lp.decision), uint8(swap.decision));
        assertEq(lp.feeBps, swap.feeBps);
        assertEq(uint8(lp.revertKind), uint8(swap.revertKind));
        assertEq(uint8(lp.decision), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(lp.feeBps, 300);
    }

    function test_NeverScoredLargeRevertsLikeSwap() external view {
        IRiskPolicy.DecisionInput memory i = _usd(0, 0, false, 0, true, 15_000e8, 0, 1_000e8, 15_000e8);
        IRiskPolicy.DecisionResult memory r = lpPolicy.decide(i);
        assertEq(uint8(r.decision), uint8(HookDecision.REVERT));
        assertEq(uint8(r.revertKind), uint8(IRiskPolicy.RevertKind.UnscoredMagnitude));
    }

    function test_Score71Reverts() external view {
        IRiskPolicy.DecisionResult memory r = lpPolicy.decide(_in(71, 0));
        assertEq(uint8(r.decision), uint8(HookDecision.REVERT));
    }

    function test_NeverScoredFloorCMatchesSwap() external view {
        IRiskPolicy.DecisionInput memory i = _usd(0, 0, false, 0, true, 5_000e8, 0, 1_000e8, 15_000e8);
        i.swapUsd = 5_000e8;
        i.priorDailyUsd = 10_000e8;
        IRiskPolicy.DecisionResult memory lp = LpPolicyLib.decide(i);
        IRiskPolicy.DecisionResult memory swap = RiskPolicyLib.decide(i);
        assertEq(uint8(lp.decision), uint8(swap.decision));
        assertEq(uint8(lp.revertKind), uint8(swap.revertKind));
        assertEq(uint8(lp.decision), uint8(HookDecision.REVERT));
        assertEq(uint8(lp.revertKind), uint8(IRiskPolicy.RevertKind.DailyAggregation));
    }

    function test_NeverScoredFloorDMatchesSwap() external view {
        IRiskPolicy.DecisionInput memory i = _usd(0, 0, false, 0, true, 100e8, 15_000e8, 1_000e8, 15_000e8);
        IRiskPolicy.DecisionResult memory lp = LpPolicyLib.decide(i);
        IRiskPolicy.DecisionResult memory swap = RiskPolicyLib.decide(i);
        assertEq(uint8(lp.decision), uint8(swap.decision));
        assertEq(lp.feeBps, swap.feeBps);
        assertEq(uint8(lp.decision), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(lp.feeBps, 800);
    }
}
