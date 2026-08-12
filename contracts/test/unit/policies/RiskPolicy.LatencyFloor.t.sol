// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @notice RiskPolicy.decide — latency-floor elevation (stale ops / significant inflow).
contract UnitRiskPolicyLatencyFloorTest is Helpers {
    function setUp() public {
        riskPolicy = new RiskPolicy();
    }

    function test_StaleWithOps_FloorsAllowToFeeOverride() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(10, 0, true, 1, false);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        // Latency floor uses 8%, not score-band proportional fallback
        assertEq(fee, riskPolicy.LATENCY_FEE_BPS());
    }

    function test_StaleWithoutOps_StillAllows() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(10, 0, true, 0, false);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_SignificantInflow_FloorsAllowToFeeOverride() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(5, 0, false, 0, true);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, riskPolicy.LATENCY_FEE_BPS());
    }

    function test_StaleAndInflow_DoNotStackBeyondFloor() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(10, 0, true, 2, true);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, riskPolicy.LATENCY_FEE_BPS());
    }

    function test_LatencyFloor_DoesNotSoftenRevert() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(100, 0, true, 5, true);
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function test_LatencyFloor_PreservesPolicyFeeOverride() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(65, 800, true, 5, true);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_LatencyFloor_UsesRecommendedFeeWhenPresent() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(10, 500, true, 1, false);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 500);
    }
}
