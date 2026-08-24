// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @notice RiskPolicy.decide — never-scored USD magnitude bands (Mitigation A).
contract UnitRiskPolicyUnscoredMagnitudeTest is Helpers {
    uint256 internal constant FEE_THRESHOLD = 1_000e8;
    uint256 internal constant REVERT_THRESHOLD = 15_000e8;

    function setUp() public {
        riskPolicy = new RiskPolicy();
    }

    function test_UnscoredBelowFeeThreshold_ReducedFee() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(0, 0, false, 0, false, true, FEE_THRESHOLD - 1, 0, FEE_THRESHOLD, REVERT_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_UnscoredAtFeeThreshold_StandardLatencyFee() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(0, 0, false, 0, false, true, FEE_THRESHOLD, 0, FEE_THRESHOLD, REVERT_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_UnscoredBetweenThresholds_StandardLatencyFee() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(0, 0, false, 0, false, true, 5_000e8, 0, FEE_THRESHOLD, REVERT_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_UnscoredAtRevertThreshold_Reverts() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(0, 0, false, 0, false, true, REVERT_THRESHOLD, 0, FEE_THRESHOLD, REVERT_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function test_UnscoredAboveRevertThreshold_Reverts() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(0, 0, false, 0, false, true, REVERT_THRESHOLD + 1, 0, FEE_THRESHOLD, REVERT_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function test_PublishedScoreZero_IgnoresSwapUsd() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(0, 0, false, 0, false, false, REVERT_THRESHOLD + 100e8, 0, FEE_THRESHOLD, REVERT_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    /// @dev Residual policy math: a zero high threshold still disables A's hard block.
    ///      The hook setter can no longer store this (`revert` must stay > fee).
    function test_ZeroRevertThreshold_DisablesHardBlock() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(0, 0, false, 0, false, true, 10_000_000e8, 0, FEE_THRESHOLD, 0);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_ScoreRevertBand_StillWinsFirst() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(80, 0, false, 0, false, true, 1, 0, FEE_THRESHOLD, REVERT_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function test_FiveArgOverload_UnchangedForCleanScore() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(0, 800, false, 0, false);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_PublishedScore_LargeInflowUsd_Charges8Percent() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(0, 0, false, 0, false, false, 1e8, REVERT_THRESHOLD, FEE_THRESHOLD, REVERT_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_UnscoredDustSwap_LargeBag_Charges8Percent() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(0, 0, false, 0, false, true, 500e8, 80_000e8, FEE_THRESHOLD, REVERT_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_PublishedScore_DustInflow_Allows() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(0, 0, false, 0, true, false, 1e8, 150e8, FEE_THRESHOLD, REVERT_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }
}
