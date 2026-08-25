// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

contract UnitRiskPolicyFloorFeesTest is Helpers {
    uint256 internal constant FEE_THRESHOLD = 1_000e8;
    uint256 internal constant REVERT_THRESHOLD = 15_000e8;
    uint24 internal constant PROP = 111;
    uint24 internal constant PUN = 2_222;

    function setUp() public {
        riskPolicy = new RiskPolicy();
    }

    function test_ScoreCutsStayHardcoded_EvenWithCustomFees() external view {
        (HookDecision d30,) =
            _dec(_fees(_usd(30, 0, false, 0, false, 0, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(uint8(d30), uint8(HookDecision.ALLOW));

        (HookDecision d31,) =
            _dec(_fees(_usd(31, 0, false, 0, false, 0, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(uint8(d31), uint8(HookDecision.FEE_OVERRIDE));

        (HookDecision d70,) =
            _dec(_fees(_usd(70, 0, false, 0, false, 0, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(uint8(d70), uint8(HookDecision.FEE_OVERRIDE));

        (HookDecision d71, uint24 f71) =
            _dec(_fees(_usd(71, 0, false, 0, false, 0, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(uint8(d71), uint8(HookDecision.REVERT));
        assertEq(f71, 0);

        (, uint24 at54) = _dec(_fees(_usd(54, 0, false, 0, false, 0, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(at54, PROP);
        (, uint24 at55) = _dec(_fees(_usd(55, 0, false, 0, false, 0, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(at55, PUN);
    }

    function test_HopFallbackUsesLiveFloorFees_NotConstants() external view {
        (, uint24 high) = _dec(_fees(_usd(65, 0, false, 0, false, 0, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(high, PUN);
        (, uint24 low) = _dec(_fees(_usd(42, 0, false, 0, false, 0, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(low, PROP);
    }

    function test_MaxOverrideStillCapsKeeperRecommendedFeeOnly() external view {
        (, uint24 accepted) =
            _dec(_fees(_usd(50, 1_000, false, 0, false, 0, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(accepted, 1_000);
        (, uint24 rejected) =
            _dec(_fees(_usd(65, 1_001, false, 0, false, 0, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(rejected, PUN);
    }

    function test_MaxOverrideDoesNotCapLiveFloorFees() external view {
        (HookDecision d, uint24 fee) =
            _dec(_fees(_usd(0, 0, false, 0, true, FEE_THRESHOLD, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, PUN);
        assertTrue(fee > riskPolicy.MAX_OVERRIDE_FEE_BPS());
    }

    function test_UnscoredDustUsesLiveProportional() external view {
        (HookDecision d, uint24 fee) =
            _dec(_fees(_usd(0, 0, false, 0, true, FEE_THRESHOLD - 1, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, PROP);
    }

    function test_StaleMidUsesLiveProportional() external view {
        (HookDecision d, uint24 fee) =
            _dec(_fees(_usd(10, 0, true, 1, false, FEE_THRESHOLD, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, PROP);
    }

    function test_StaleHighUsesLivePunitive() external view {
        (HookDecision d, uint24 fee) =
            _dec(_fees(_usd(10, 0, true, 1, false, REVERT_THRESHOLD, 0, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, PUN);
    }

    function test_InflowHighUsesLivePunitive() external view {
        (HookDecision d, uint24 fee) =
            _dec(_fees(_usd(0, 0, false, 0, false, 1e8, REVERT_THRESHOLD, FEE_THRESHOLD, REVERT_THRESHOLD), PROP, PUN));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, PUN);
    }

    function test_DefaultFloorFees() external view {
        (, uint24 dust) = _dec(_usd(0, 0, false, 0, true, FEE_THRESHOLD - 1, 0, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(dust, 300);
        (, uint24 mid) = _dec(_usd(0, 0, false, 0, true, FEE_THRESHOLD, 0, FEE_THRESHOLD, REVERT_THRESHOLD));
        assertEq(mid, 800);
    }
}
