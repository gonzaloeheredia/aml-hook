// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {HelpersCore} from "test/utils/HelpersCore.t.sol";

contract UnitRiskPolicyUnscoredMagnitudeTest is HelpersCore {
    uint256 internal constant FEE_THRESHOLD = 1_000e8;
    uint256 internal constant REVERT_THRESHOLD = 15_000e8;

    function setUp() public {
        riskPolicy = new RiskPolicy();
    }

    function test_UnscoredBelowFeeThreshold_ReducedFee() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(0, 0, false, 0, true, FEE_THRESHOLD - 1, 0, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_UnscoredAtFeeThreshold_StandardLatencyFee() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(0, 0, false, 0, true, FEE_THRESHOLD, 0, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_UnscoredBetweenThresholds_StandardLatencyFee() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(0, 0, false, 0, true, 5_000e8, 0, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_UnscoredAtRevertThreshold_Reverts() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(0, 0, false, 0, true, REVERT_THRESHOLD, 0, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function test_UnscoredAboveRevertThreshold_Reverts() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(0, 0, false, 0, true, REVERT_THRESHOLD + 1, 0, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function test_PublishedScoreZero_IgnoresSwapUsd() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(0, 0, false, 0, false, REVERT_THRESHOLD + 100e8, 0, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_ZeroRevertThreshold_DisablesHardBlock() external view {
        (HookDecision d, uint24 fee) = _dec(_usd(0, 0, false, 0, true, 10_000_000e8, 0, FEE_THRESHOLD, 0));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_ScoreRevertBand_StillWinsFirst() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(80, 0, false, 0, true, 1, 0, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function test_CleanScore_Unchanged() external view {
        (HookDecision d, uint24 fee) = _dec(_in(0, 800));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_PublishedScore_LargeInflowUsd_Charges8Percent() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(0, 0, false, 0, false, 1e8, REVERT_THRESHOLD, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_UnscoredDustSwap_LargeBag_Charges8Percent() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(0, 0, false, 0, true, 500e8, 80_000e8, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_PublishedScore_DustInflow_Allows() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(0, 0, false, 0, false, 1e8, 150e8, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }
}
