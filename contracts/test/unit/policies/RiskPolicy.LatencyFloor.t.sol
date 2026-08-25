// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {HelpersCore} from "test/utils/HelpersCore.t.sol";

contract UnitRiskPolicyLatencyFloorTest is HelpersCore {
    uint256 internal constant FEE_THRESHOLD = 1_000e8;
    uint256 internal constant HIGH_THRESHOLD = 15_000e8;

    function setUp() public {
        riskPolicy = new RiskPolicy();
    }

    function test_StaleDust_StillAllows() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(10, 0, true, 1, false, FEE_THRESHOLD - 1, 0, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_StaleMid_Charges3Percent() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(10, 0, true, 1, false, FEE_THRESHOLD, 0, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_StaleHigh_Charges8Percent() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(10, 0, true, 1, false, HIGH_THRESHOLD, 0, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_StaleWithoutOps_ChargesProportional() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(10, 0, true, 0, false, HIGH_THRESHOLD, 0, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_StaleWithoutOps_DustBelowThreshold_ChargesProportional() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(10, 0, true, 0, false, FEE_THRESHOLD - 1, 0, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_StaleWithoutOps_UsesLiveProportionalFee() external view {
        (HookDecision d, uint24 fee) = _dec(
            _fees(_usd(10, 0, true, 0, false, HIGH_THRESHOLD, 0, FEE_THRESHOLD, HIGH_THRESHOLD), 500, 800)
        );
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 500);
    }

    function test_InflowDust_StillAllows() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(5, 0, false, 0, false, 0, FEE_THRESHOLD - 1, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_InflowMid_Charges3Percent() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(5, 0, false, 0, false, 0, 5_000e8, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_InflowHigh_Charges8Percent_DoesNotRevert() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(0, 0, false, 0, false, 1e8, HIGH_THRESHOLD, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_StaleAndInflow_TakeStricterFee() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(10, 0, true, 2, false, FEE_THRESHOLD, HIGH_THRESHOLD, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_LatencyFloor_DoesNotSoftenRevert() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(100, 0, true, 5, false, HIGH_THRESHOLD, HIGH_THRESHOLD, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function test_LatencyFloor_PreservesPolicyFeeOverride() external view {
        (HookDecision d, uint24 fee) =
            _dec(_usd(65, 800, true, 5, false, HIGH_THRESHOLD, HIGH_THRESHOLD, FEE_THRESHOLD, HIGH_THRESHOLD));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_WithoutUsd_DoesNotElevate() external view {
        (HookDecision d, uint24 fee) = _dec(_in(10, 0, true, 1));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }
}
