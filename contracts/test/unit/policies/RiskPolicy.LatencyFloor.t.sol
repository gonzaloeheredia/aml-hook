// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @notice RiskPolicy.decide — Floor B / D published USD bands (pass / 3% / 8%).
contract UnitRiskPolicyLatencyFloorTest is Helpers {
    uint256 internal constant FEE_THRESHOLD = 1_000e8;
    uint256 internal constant HIGH_THRESHOLD = 15_000e8;

    function setUp() public {
        riskPolicy = new RiskPolicy();
    }

    function test_StaleDust_StillAllows() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(10, 0, true, 1, false, false, FEE_THRESHOLD - 1, 0, FEE_THRESHOLD, HIGH_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_StaleMid_Charges3Percent() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(10, 0, true, 1, false, false, FEE_THRESHOLD, 0, FEE_THRESHOLD, HIGH_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_StaleHigh_Charges8Percent() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(10, 0, true, 1, false, false, HIGH_THRESHOLD, 0, FEE_THRESHOLD, HIGH_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_StaleWithoutOps_StillAllows() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(10, 0, true, 0, false, false, HIGH_THRESHOLD, 0, FEE_THRESHOLD, HIGH_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_InflowDust_StillAllows() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(5, 0, false, 0, true, false, 0, FEE_THRESHOLD - 1, FEE_THRESHOLD, HIGH_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_InflowMid_Charges3Percent() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(5, 0, false, 0, true, false, 0, 5_000e8, FEE_THRESHOLD, HIGH_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_InflowHigh_Charges8Percent_DoesNotRevert() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(0, 0, false, 0, false, false, 1e8, HIGH_THRESHOLD, FEE_THRESHOLD, HIGH_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_StaleAndInflow_TakeStricterFee() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(10, 0, true, 2, true, false, FEE_THRESHOLD, HIGH_THRESHOLD, FEE_THRESHOLD, HIGH_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_LatencyFloor_DoesNotSoftenRevert() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(100, 0, true, 5, true, false, HIGH_THRESHOLD, HIGH_THRESHOLD, FEE_THRESHOLD, HIGH_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function test_LatencyFloor_PreservesPolicyFeeOverride() external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(65, 800, true, 5, true, false, HIGH_THRESHOLD, HIGH_THRESHOLD, FEE_THRESHOLD, HIGH_THRESHOLD);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_FiveArgOverload_WithoutUsd_DoesNotElevate() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(10, 0, true, 1, true);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }
}
