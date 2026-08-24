// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @notice Fuzz invariants for every `RiskPolicy.decide` overload (score bands, A/B/D floors).
contract UnitRiskPolicyFuzzTest is Helpers {
    uint256 internal constant FEE_FLOOR = 1_000e8;
    uint256 internal constant HIGH_FLOOR = 15_000e8;

    function setUp() public {
        riskPolicy = new RiskPolicy();
    }

    function testFuzz_FiveArg_ScoreBandsArePartition(
        uint8 score,
        uint24 recommendedFeeBps,
        bool isStale,
        uint32 operationCount,
        bool hasSignificantInflow
    ) external view {
        (HookDecision d, uint24 fee) =
            riskPolicy.decide(score, recommendedFeeBps, isStale, operationCount, hasSignificantInflow);

        if (score >= 71) {
            assertEq(uint8(d), uint8(HookDecision.REVERT));
            assertEq(fee, 0);
        } else if (score >= 31) {
            assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
            assertGt(fee, 0);
            assertLe(fee, riskPolicy.MAX_OVERRIDE_FEE_BPS());
        } else {
            // 5-arg form has no USD; B/D cannot elevate.
            assertEq(uint8(d), uint8(HookDecision.ALLOW));
            assertEq(fee, 0);
        }
    }

    function testFuzz_RevertBandNeverSoftened(
        uint8 score,
        uint24 recommended,
        bool isStale,
        uint32 ops,
        bool inflowFlag,
        bool neverScored,
        uint256 assessedUsd,
        uint256 inflowUsd,
        uint24 prop,
        uint24 pun
    ) external view {
        score = uint8(bound(score, 71, 100));
        pun = uint24(bound(pun, 1, type(uint24).max));
        prop = uint24(bound(prop, 0, pun - 1));

        (HookDecision d, uint24 fee) = riskPolicy.decide(
            score, recommended, isStale, ops, inflowFlag, neverScored, assessedUsd, inflowUsd, FEE_FLOOR, HIGH_FLOOR, prop, pun
        );
        assertEq(uint8(d), uint8(HookDecision.REVERT));
        assertEq(fee, 0);
    }

    function testFuzz_NeverScoredUsdBands(
        uint256 assessedUsd,
        uint256 inflowUsd,
        uint24 prop,
        uint24 pun
    ) external view {
        pun = uint24(bound(pun, 1, type(uint24).max));
        prop = uint24(bound(prop, 0, pun - 1));

        (HookDecision d, uint24 fee) = riskPolicy.decide(
            0, 0, false, 0, false, true, assessedUsd, inflowUsd, FEE_FLOOR, HIGH_FLOOR, prop, pun
        );

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

        (HookDecision d,) = riskPolicy.decide(
            score, recommended, isStale, ops, false, false, assessedUsd, inflowUsd, FEE_FLOOR, HIGH_FLOOR, prop, pun
        );
        assertTrue(d != HookDecision.REVERT);
        if (score >= 31) assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
    }

    function testFuzz_StaleOpsUsesAssessedUsdBand(uint256 assessedUsd, uint24 prop, uint24 pun) external view {
        pun = uint24(bound(pun, 1, type(uint24).max));
        prop = uint24(bound(prop, 0, pun - 1));

        (HookDecision d, uint24 fee) = riskPolicy.decide(
            0, 0, true, 1, false, false, assessedUsd, 0, FEE_FLOOR, HIGH_FLOOR, prop, pun
        );

        if (assessedUsd >= HIGH_FLOOR) {
            assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
            assertEq(fee, pun);
        } else if (assessedUsd >= FEE_FLOOR) {
            assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
            assertEq(fee, prop);
        } else {
            assertEq(uint8(d), uint8(HookDecision.ALLOW));
            assertEq(fee, 0);
        }
    }

    function testFuzz_TenArgMatchesTwelveArgDefaults(
        uint8 score,
        uint24 recommended,
        bool isStale,
        uint32 ops,
        bool neverScored,
        uint256 assessedUsd,
        uint256 inflowUsd
    ) external view {
        (HookDecision d10, uint24 f10) = riskPolicy.decide(
            score, recommended, isStale, ops, false, neverScored, assessedUsd, inflowUsd, FEE_FLOOR, HIGH_FLOOR
        );
        (HookDecision d12, uint24 f12) = riskPolicy.decide(
            score,
            recommended,
            isStale,
            ops,
            false,
            neverScored,
            assessedUsd,
            inflowUsd,
            FEE_FLOOR,
            HIGH_FLOOR,
            riskPolicy.PROPORTIONAL_FEE_BPS(),
            riskPolicy.PUNITIVE_FEE_BPS()
        );
        assertEq(uint8(d10), uint8(d12));
        assertEq(f10, f12);
    }

    function testFuzz_KeeperRecommendedFeeUsedWhenInCap(uint8 score, uint24 recommended) external view {
        score = uint8(bound(score, 31, 70));
        recommended = uint24(bound(recommended, 1, riskPolicy.MAX_OVERRIDE_FEE_BPS()));
        (, uint24 fee) = riskPolicy.decide(score, recommended, false, 0, false);
        assertEq(fee, recommended);
    }
}
