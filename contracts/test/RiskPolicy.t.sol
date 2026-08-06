// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RiskPolicy} from "../src/policy/RiskPolicy.sol";
import {HookDecision} from "../src/libraries/HookDecision.sol";

contract RiskPolicyTest is Test {
    RiskPolicy policy;

    function setUp() public {
        policy = new RiskPolicy();
    }

    function test_AllowBandBoundaries() public view {
        (HookDecision d0, uint24 f0) = policy.decide(0, 800);
        assertEq(uint8(d0), uint8(HookDecision.ALLOW));
        assertEq(f0, 0);

        (HookDecision d30, uint24 f30) = policy.decide(30, 800);
        assertEq(uint8(d30), uint8(HookDecision.ALLOW));
        assertEq(f30, 0);
    }

    function test_FeeOverrideUsesKeeperWrittenFee() public view {
        // On-chain input is keeper-written feeBps (oracle storage), not the COA runtime itself.
        (HookDecision d, uint24 fee) = policy.decide(65, 800);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);

        (HookDecision d2, uint24 fee2) = policy.decide(42, 300);
        assertEq(uint8(d2), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee2, 300);
    }

    function test_FeeOverrideBandBoundaries() public view {
        (HookDecision d31,) = policy.decide(31, 500);
        assertEq(uint8(d31), uint8(HookDecision.FEE_OVERRIDE));

        (HookDecision d70,) = policy.decide(70, 500);
        assertEq(uint8(d70), uint8(HookDecision.FEE_OVERRIDE));
    }

    function test_RevertBand() public view {
        (HookDecision d71, uint24 f71) = policy.decide(71, 800);
        assertEq(uint8(d71), uint8(HookDecision.REVERT));
        assertEq(f71, 0);

        (HookDecision d100, uint24 f100) = policy.decide(100, 800);
        assertEq(uint8(d100), uint8(HookDecision.REVERT));
        assertEq(f100, 0);
    }

    function test_FallbackWhenOracleFeeZero() public view {
        // score >= 55 → punitive 800
        (, uint24 high) = policy.decide(65, 0);
        assertEq(high, 800);
        // score < 55 → proportional 300
        (, uint24 low) = policy.decide(42, 0);
        assertEq(low, 300);
    }

    function test_FallbackWhenOracleFeeAboveCap() public view {
        // 1001 > MAX 1000 → ignore keeper fee, use score fallback
        (, uint24 fee) = policy.decide(65, 1001);
        assertEq(fee, 800);
    }

    function test_AcceptsMaxOverrideFee() public view {
        (, uint24 fee) = policy.decide(50, 1000);
        assertEq(fee, 1000);
    }

    function test_Constants() public view {
        assertEq(policy.STANDARD_FEE_BPS(), 30);
        assertEq(policy.PUNITIVE_FEE_BPS(), 800);
        assertEq(policy.PROPORTIONAL_FEE_BPS(), 300);
        assertEq(policy.MAX_OVERRIDE_FEE_BPS(), 1000);
    }
}
