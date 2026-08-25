// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {IRiskPolicy} from "interfaces/policies/IRiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

contract UnitRiskPolicyFuzzTest is Helpers {
    uint256 internal constant FEE_FLOOR = 1_000e8;
    uint256 internal constant HIGH_FLOOR = 15_000e8;

    function setUp() public {
        riskPolicy = new RiskPolicy();
    }

    function testFuzz_ScoreBandsArePartition(uint8 score, uint24 recommendedFeeBps, bool isStale, uint32 operationCount)
        external
        view
    {
        (HookDecision d, uint24 fee) = _dec(_in(score, recommendedFeeBps, isStale, operationCount));

        if (score >= 71) {
            assertEq(uint8(d), uint8(HookDecision.REVERT));
            assertEq(fee, 0);
        } else if (score >= 31) {
            assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
            assertGt(fee, 0);
            assertLe(fee, riskPolicy.MAX_OVERRIDE_FEE_BPS());
        } else if (isStale && operationCount == 0) {
            assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
            assertEq(fee, riskPolicy.PROPORTIONAL_FEE_BPS());
        } else {
            assertEq(uint8(d), uint8(HookDecision.ALLOW));
            assertEq(fee, 0);
        }
    }

    function testFuzz_RevertBandNeverSoftened(
        uint8 score,
        uint24 recommended,
        bool isStale,
        uint32 ops,
        bool neverScored,
        uint256 assessedUsd,
        uint256 inflowUsd,
        uint24 prop,
        uint24 pun
    ) external view {
        score = uint8(bound(score, 71, 100));
        pun = uint24(bound(pun, 1, type(uint24).max));
        prop = uint24(bound(prop, 0, pun - 1));

        (HookDecision d, uint24 fee) = _dec(
            _fees(_usd(score, recommended, isStale, ops, neverScored, assessedUsd, inflowUsd, FEE_FLOOR, HIGH_FLOOR), prop, pun)
        );
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function testFuzz_NeverScoredUsdBands(uint256 assessedUsd, uint256 inflowUsd, uint24 prop, uint24 pun)
        external
        view
    {
        pun = uint24(bound(pun, 1, type(uint24).max));
        prop = uint24(bound(prop, 0, pun - 1));

        (HookDecision d, uint24 fee) =
            _dec(_fees(_usd(0, 0, false, 0, true, assessedUsd, inflowUsd, FEE_FLOOR, HIGH_FLOOR), prop, pun));

        if (assessedUsd >= HIGH_FLOOR) {
            assertEq(uint8(d), uint8(HookDecision.REVERT));
            assertEq(fee, 0);
            return;
        }

        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        uint24 aFee = assessedUsd < FEE_FLOOR ? prop : pun;
        uint24 bagFee = inflowUsd >= HIGH_FLOOR ? pun : (inflowUsd >= FEE_FLOOR ? prop : 0);
        assertEq(fee, aFee > bagFee ? aFee : bagFee);
    }

    function testFuzz_PublishedScoreNeverRevertsFromUsdFloors(
        uint8 score,
        uint24 recommended,
        bool isStale,
        uint32 ops,
        uint256 assessedUsd,
        uint256 inflowUsd,
        uint24 prop,
        uint24 pun
    ) external view {
        score = uint8(bound(score, 0, 70));
        pun = uint24(bound(pun, 1, type(uint24).max));
        prop = uint24(bound(prop, 0, pun - 1));

        (HookDecision d,) =
            _dec(_fees(_usd(score, recommended, isStale, ops, false, assessedUsd, inflowUsd, FEE_FLOOR, HIGH_FLOOR), prop, pun));
        assertTrue(d != HookDecision.REVERT);
        if (score >= 31) assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
    }

    function testFuzz_StaleOpsUsesAssessedUsdBand(uint256 assessedUsd, uint24 prop, uint24 pun) external view {
        pun = uint24(bound(pun, 1, type(uint24).max));
        prop = uint24(bound(prop, 0, pun - 1));

        (HookDecision d, uint24 fee) =
            _dec(_fees(_usd(0, 0, true, 1, false, assessedUsd, 0, FEE_FLOOR, HIGH_FLOOR), prop, pun));

        if (assessedUsd >= HIGH_FLOOR) {
            assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
            assertEq(fee, pun);
        } else if (assessedUsd >= FEE_FLOOR) {
            if (prop == 0) {
                assertEq(uint8(d), uint8(HookDecision.ALLOW));
                assertEq(fee, 0);
            } else {
                assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
                assertEq(fee, prop);
            }
        } else {
            assertEq(uint8(d), uint8(HookDecision.ALLOW));
            assertEq(fee, 0);
        }
    }

    function testFuzz_KeeperRecommendedFeeUsedWhenInCap(uint8 score, uint24 recommended) external view {
        score = uint8(bound(score, 31, 70));
        recommended = uint24(bound(recommended, 1, riskPolicy.MAX_OVERRIDE_FEE_BPS()));
        (, uint24 fee) = _dec(_in(score, recommended));
        assertEq(fee, recommended);
    }

    function testFuzz_StaleAndInflowTakeStricterFee(uint256 assessedUsd, uint256 inflowUsd, uint24 prop, uint24 pun)
        external
        view
    {
        pun = uint24(bound(pun, 1, type(uint24).max));
        prop = uint24(bound(prop, 0, pun - 1));

        (HookDecision d, uint24 fee) =
            _dec(_fees(_usd(0, 0, true, 1, false, assessedUsd, inflowUsd, FEE_FLOOR, HIGH_FLOOR), prop, pun));

        uint24 bFee = assessedUsd >= HIGH_FLOOR ? pun : (assessedUsd >= FEE_FLOOR ? prop : 0);
        uint24 dFee = inflowUsd >= HIGH_FLOOR ? pun : (inflowUsd >= FEE_FLOOR ? prop : 0);
        uint24 expected = bFee > dFee ? bFee : dFee;

        if (expected == 0) {
            assertEq(uint8(d), uint8(HookDecision.ALLOW));
            assertEq(fee, 0);
        } else {
            assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
            assertEq(fee, expected);
        }
    }

    function testFuzz_HopFallbackWhenRecommendedOutOfCap(uint8 score, uint24 recommended) external view {
        score = uint8(bound(score, 31, 70));
        if (recommended > 0 && recommended <= riskPolicy.MAX_OVERRIDE_FEE_BPS()) {
            recommended = uint24(bound(uint256(recommended) + 1, 1001, type(uint24).max));
        }
        (, uint24 fee) = _dec(_in(score, recommended));
        uint24 expected = score >= 55 ? riskPolicy.PUNITIVE_FEE_BPS() : riskPolicy.PROPORTIONAL_FEE_BPS();
        assertEq(fee, expected);
    }

    function testFuzz_DailyAggregationRevertsWhenPriorPlusSwapCrosses(uint256 prior, uint256 swapUsd) external view {
        prior = bound(prior, 1, HIGH_FLOOR);
        swapUsd = bound(swapUsd, 0, HIGH_FLOOR);
        IRiskPolicy.DecisionInput memory i = _in(0, 0);
        i.unscoredFeeThreshold = FEE_FLOOR;
        i.unscoredRevertThreshold = HIGH_FLOOR;
        i.priorDailyUsd = prior;
        i.swapUsd = swapUsd;
        IRiskPolicy.DecisionResult memory r = riskPolicy.decide(i);
        if (prior + swapUsd >= HIGH_FLOOR) {
            assertEq(uint8(r.decision), uint8(HookDecision.REVERT));
            assertEq(uint8(r.revertKind), uint8(IRiskPolicy.RevertKind.DailyAggregation));
        } else {
            assertEq(uint8(r.decision), uint8(HookDecision.ALLOW));
        }
    }
}
