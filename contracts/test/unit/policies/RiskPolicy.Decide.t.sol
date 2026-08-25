// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

contract UnitRiskPolicyDecideTest is Helpers {
    function setUp() public {
        riskPolicy = new RiskPolicy();
    }

    function test_AllowBandBoundaries() external view {
        (HookDecision d0, uint24 f0) = _dec(_in(0, 800));
        assertEq(uint8(d0), uint8(HookDecision.ALLOW));
        assertEq(f0, 0);

        (HookDecision d30, uint24 f30) = _dec(_in(30, 800));
        assertEq(uint8(d30), uint8(HookDecision.ALLOW));
        assertEq(f30, 0);
    }

    function test_FeeOverrideUsesKeeperWrittenFee() external view {
        (HookDecision d, uint24 fee) = _dec(_in(65, 800));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);

        (HookDecision d2, uint24 fee2) = _dec(_in(42, 300));
        assertEq(uint8(d2), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee2, 300);
    }

    function test_FeeOverrideBandBoundaries() external view {
        (HookDecision d31,) = _dec(_in(31, 500));
        assertEq(uint8(d31), uint8(HookDecision.FEE_OVERRIDE));
        (HookDecision d70,) = _dec(_in(70, 500));
        assertEq(uint8(d70), uint8(HookDecision.FEE_OVERRIDE));
    }

    function test_RevertBand() external view {
        (HookDecision d71, uint24 f71) = _dec(_in(71, 800));
        assertEq(uint8(d71), uint8(HookDecision.REVERT));
        assertEq(f71, 0);
        (HookDecision d100, uint24 f100) = _dec(_in(100, 800));
        assertEq(uint8(d100), uint8(HookDecision.REVERT));
        assertEq(f100, 0);
    }

    function test_FallbackWhenOracleFeeZero() external view {
        (, uint24 high) = _dec(_in(65, 0));
        assertEq(high, 800);
        (, uint24 low) = _dec(_in(42, 0));
        assertEq(low, 300);
    }

    function test_FallbackWhenOracleFeeAboveCap() external view {
        (, uint24 fee) = _dec(_in(65, 1001));
        assertEq(fee, 800);
    }

    function test_AcceptsMaxOverrideFee() external view {
        (, uint24 fee) = _dec(_in(50, 1000));
        assertEq(fee, 1000);
    }

    function test_Constants() external view {
        assertEq(riskPolicy.STANDARD_FEE_BPS(), 30);
        assertEq(riskPolicy.PUNITIVE_FEE_BPS(), 800);
        assertEq(riskPolicy.PROPORTIONAL_FEE_BPS(), 300);
        assertEq(riskPolicy.LATENCY_FEE_BPS(), 800);
        assertEq(riskPolicy.MAX_OVERRIDE_FEE_BPS(), 1000);
    }

    function test_DecideWhenAnythingIsChargedStaysUnderThePoolMaximum(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount
    ) external view {
        (, uint24 applied) = _dec(_in(score, recommendedFeeBps, isStale, operationCount));
        assertLe(applied, riskPolicy.MAX_OVERRIDE_FEE_BPS());
    }

    function test_DecideWhenScoreIsClean(uint8 score) external view {
        score = uint8(bound(score, 0, 30));
        (HookDecision d, uint24 fee) = _dec(_in(score, 800));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_DecideWhenScoreIsInTheDifferentialBand(uint8 score) external view {
        score = uint8(bound(score, 31, 70));
        (HookDecision d, uint24 fee) = _dec(_in(score, 0));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertGt(fee, 0);
        assertLe(fee, riskPolicy.MAX_OVERRIDE_FEE_BPS());
    }

    function test_DecideWhenScoreIsInTheBlockBand(uint8 score) external view {
        score = uint8(bound(score, 71, 100));
        (HookDecision d, uint24 fee) = _dec(_in(score, 800));
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }
}
