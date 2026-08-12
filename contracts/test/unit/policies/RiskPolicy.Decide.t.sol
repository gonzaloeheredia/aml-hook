// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @notice RiskPolicy.decide — ternary score bands and fee selection (no latency floor).
contract UnitRiskPolicyDecideTest is Helpers {
    function setUp() public {
        riskPolicy = new RiskPolicy();
    }

    function test_AllowBandBoundaries() external view {
        (HookDecision d0, uint24 f0) = riskPolicy.decide(0, 800, false, 0, false);
        assertEq(uint8(d0), uint8(HookDecision.ALLOW));
        assertEq(f0, 0);

        (HookDecision d30, uint24 f30) = riskPolicy.decide(30, 800, false, 0, false);
        assertEq(uint8(d30), uint8(HookDecision.ALLOW));
        assertEq(f30, 0);
    }

    function test_FeeOverrideUsesKeeperWrittenFee() external view {
        (HookDecision d, uint24 fee) = riskPolicy.decide(65, 800, false, 0, false);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);

        (HookDecision d2, uint24 fee2) = riskPolicy.decide(42, 300, false, 0, false);
        assertEq(uint8(d2), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee2, 300);
    }

    function test_FeeOverrideBandBoundaries() external view {
        (HookDecision d31,) = riskPolicy.decide(31, 500, false, 0, false);
        assertEq(uint8(d31), uint8(HookDecision.FEE_OVERRIDE));

        (HookDecision d70,) = riskPolicy.decide(70, 500, false, 0, false);
        assertEq(uint8(d70), uint8(HookDecision.FEE_OVERRIDE));
    }

    function test_RevertBand() external view {
        (HookDecision d71, uint24 f71) = riskPolicy.decide(71, 800, false, 0, false);
        assertEq(uint8(d71), uint8(HookDecision.REVERT));
        assertEq(f71, 0);

        (HookDecision d100, uint24 f100) = riskPolicy.decide(100, 800, false, 0, false);
        assertEq(uint8(d100), uint8(HookDecision.REVERT));
        assertEq(f100, 0);
    }

    function test_FallbackWhenOracleFeeZero() external view {
        (, uint24 high) = riskPolicy.decide(65, 0, false, 0, false);
        assertEq(high, 800);
        (, uint24 low) = riskPolicy.decide(42, 0, false, 0, false);
        assertEq(low, 300);
    }

    function test_FallbackWhenOracleFeeAboveCap() external view {
        (, uint24 fee) = riskPolicy.decide(65, 1001, false, 0, false);
        assertEq(fee, 800);
    }

    function test_AcceptsMaxOverrideFee() external view {
        (, uint24 fee) = riskPolicy.decide(50, 1000, false, 0, false);
        assertEq(fee, 1000);
    }

    function test_Constants() external view {
        assertEq(riskPolicy.STANDARD_FEE_BPS(), 30);
        assertEq(riskPolicy.PUNITIVE_FEE_BPS(), 800);
        assertEq(riskPolicy.PROPORTIONAL_FEE_BPS(), 300);
        assertEq(riskPolicy.LATENCY_FEE_BPS(), 800);
        assertEq(riskPolicy.MAX_OVERRIDE_FEE_BPS(), 1000);
    }
}
