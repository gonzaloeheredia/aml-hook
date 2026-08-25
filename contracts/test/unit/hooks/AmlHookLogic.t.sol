// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {AmlHookGovernance} from "contracts/hooks/AmlHookGovernance.sol";
import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {AmlHookHarness} from "./AmlHookHarness.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";
import {HelpersCore} from "test/utils/HelpersCore.t.sol";

/// @notice AmlHookLogic §3.8 oracle-latency mitigations (unset / stale / inflow / activity cap).
contract UnitAmlHookLogicTest is HelpersCore {
    AmlHookHarness harness;
    MockERC20 token;
    MockAggregatorV3 feed;

    uint256 internal constant USD_1 = 1e8;
    uint256 internal constant USD_1000 = 1_000e8;
    uint256 internal constant USD_15000 = 15_000e8;

    event LatencyMitigationApplied(
        address indexed wallet, bytes32 reason, uint24 feeBps, uint8 oracleScore
    );

    event InflowHeuristicTriggered(address indexed wallet, uint256 deltaBps, uint256 timestamp);

    function setUp() public {
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        // staleness=100, window=1000
        harness = new AmlHookHarness(address(accessManager), sanctionRegistry, complianceOracle, riskPolicy, 100, 1000);
        token = new MockERC20();

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory hookSelectors = new bytes4[](9);
        hookSelectors[0] = AmlHookGovernance.setStalenessThreshold.selector;
        hookSelectors[1] = AmlHookGovernance.setInflowThresholdBps.selector;
        hookSelectors[2] = AmlHookGovernance.setTrustedRouter.selector;
        hookSelectors[3] = AmlHookGovernance.setPriceFeed.selector;
        hookSelectors[4] = AmlHookGovernance.setPriceStalenessThreshold.selector;
        hookSelectors[5] = AmlHookGovernance.setActivityWindow.selector;
        hookSelectors[6] = AmlHookLogic.observeSwap.selector;
        hookSelectors[7] = AmlHookLogic.syncBaseline.selector;
        hookSelectors[8] = AmlHookGovernance.setDailyWindow.selector;
        _wireRole(accessManager, owner, address(harness), hookSelectors, Roles._HOOK_GOVERNOR, hookGovernor);
        _wireComplianceOfficer(address(harness), 0);

        vm.warp(1_000_000);
        feed = new MockAggregatorV3();
        feed.setRound(int256(USD_1), block.timestamp); // $1 per 18-decimal token
        vm.startPrank(hookGovernor);
        harness.setPriceFeed(address(0), address(feed));
        harness.setPriceFeed(address(token), address(feed));
        vm.stopPrank();
    }

    function test_UnsetScore_NotAllow() external {
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_UnsetScore_EmitsMitigationReason() external {
        vm.expectEmit(true, false, false, true, address(harness));
        emit LatencyMitigationApplied(walletA, harness.REASON_SCORE_NEVER_WRITTEN(), 300, 0);
        harness.evaluateLive(walletA);
    }

    function test_WrittenZeroScore_Allows() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_StaleWithoutPoolActivity_ChargesProportional() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        // H-01: stale score at opCount==0 (window boundary) now charges proportional, not ALLOW.
        vm.warp(block.timestamp + 101);
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_StaleWithPoolActivity_DustAllows() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0));
        vm.warp(block.timestamp + 50);
        harness.recordActivity(walletA);
        vm.warp(block.timestamp + 100);
        feed.setRound(int256(USD_1), block.timestamp);

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 999 ether);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_StaleWithPoolActivity_MidCharges3Percent() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0));
        vm.warp(block.timestamp + 50);
        harness.recordActivity(walletA);
        vm.warp(block.timestamp + 100);
        feed.setRound(int256(USD_1), block.timestamp);

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 1_000 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);

        vm.expectEmit(true, false, false, true, address(harness));
        emit LatencyMitigationApplied(walletA, harness.REASON_STALE_WITH_POOL_ACTIVITY(), 300, 10);
        harness.evaluateLive(walletA, address(token), 1_000 ether);
    }

    function test_StaleWithPoolActivity_HighCharges8Percent() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0));
        vm.warp(block.timestamp + 50);
        harness.recordActivity(walletA);
        vm.warp(block.timestamp + 100);
        feed.setRound(int256(USD_1), block.timestamp);

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 15_000 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_FreshScore_AllowsDespitePriorActivity() external {
        harness.recordActivity(walletA);
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0)); // fresh write after activity
        (HookDecision d,,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    function test_ActivityWindowCap_NoLongerElevatesOnNthOp() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        harness.recordActivity(walletA);
        harness.recordActivity(walletA);
        harness.recordActivity(walletA);
        (, uint32 ops,) = harness.poolActivity(walletA);
        assertEq(ops, 3);

        // Floor C is USD aggregation, not an op cap. Zero-size ops do not cross $15,000.
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_ActivityWindowResets() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        harness.recordActivity(walletA);
        harness.recordActivity(walletA);
        harness.recordActivity(walletA);

        vm.warp(block.timestamp + 1001); // past activityWindow=1000 and stalenessThreshold=100
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA);
        // H-01: window expired → operationCount 0; stale + opCount==0 → FEE_OVERRIDE/proportional
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_RevertBand_NotSoftenedByMitigations() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, _scoreSig(walletA, 100, 0, walletA, 0));
        vm.expectRevert();
        harness.evaluate(walletA);
    }

    function test_FeeOverrideFromPolicy_NotDoubleChanged() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 65, 1, walletA, 300, _scoreSig(walletA, 65, 1, walletA, 300));
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_SetStalenessThreshold_RestrictedToGovernor() external {
        vm.prank(hookGovernor);
        harness.setStalenessThreshold(200);
        assertEq(harness.stalenessThreshold(), 200);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setStalenessThreshold(50);
    }

    function test_SetStalenessThreshold_RevertsAboveMax() external {
        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.StalenessThresholdTooHigh.selector);
        harness.setStalenessThreshold(24 hours + 1);
    }

    function test_EvaluateViewAndLive_MatchOnUnsetScore() external {
        (HookDecision dView, uint24 feeView,) = harness.evaluate(walletA);
        (HookDecision dLive, uint24 feeLive,) = harness.evaluateLive(walletA);
        assertEq(uint8(dView), uint8(dLive));
        assertEq(feeView, feeLive);
        assertEq(uint8(dView), uint8(HookDecision.FEE_OVERRIDE));
    }

    function test_SetInflowThresholdBps_RestrictedToGovernor() external {
        assertEq(harness.inflowThresholdBps(), 5000);

        vm.prank(hookGovernor);
        harness.setInflowThresholdBps(2500);
        assertEq(harness.inflowThresholdBps(), 2500);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setInflowThresholdBps(1000);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.InflowThresholdOutOfRange.selector);
        harness.setInflowThresholdBps(0);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.InflowThresholdOutOfRange.selector);
        harness.setInflowThresholdBps(99);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.InflowThresholdOutOfRange.selector);
        harness.setInflowThresholdBps(10_001);
    }

    function test_SetInflowThresholdBps_DoesNotChangeUsdBands() external {
        // Relative 50% is audit-only. A $5,000 inbound still pays 3% after raising the share cut.
        vm.prank(hookGovernor);
        harness.setInflowThresholdBps(7000);

        token.mint(walletA, 100_000 ether);
        harness.updateKnownBalance(walletA, address(token));
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        vm.warp(block.timestamp + 10);
        feed.setRound(int256(USD_1), block.timestamp);
        token.mint(walletA, 5_000 ether); // 4.76% share, $5,000 mid band

        (HookDecision d, uint24 fee,) = harness.evaluateWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_InflowMidBand_WithStaleOracle_Charges3Percent() external {
        token.mint(walletA, 100 ether);
        harness.updateKnownBalance(walletA, address(token));
        uint256 baselineTs = block.timestamp;

        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        assertEq(uint256(complianceOracle.getRisk(walletA).updatedAt), baselineTs);

        vm.warp(block.timestamp + 10);
        feed.setRound(int256(USD_1), block.timestamp);
        token.mint(walletA, 5_000 ether);

        (HookDecision d, uint24 fee,) = harness.evaluateWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);

        vm.expectEmit(true, false, false, true, address(harness));
        emit InflowHeuristicTriggered(walletA, (uint256(5_000) * 10_000) / 5_100, block.timestamp);
        harness.evaluateLiveWithToken(walletA, address(token));
    }

    function test_InflowAboveThreshold_WithFreshOracle_Allows() external {
        token.mint(walletA, 100 ether);
        harness.updateKnownBalance(walletA, address(token));

        vm.warp(block.timestamp + 10);
        token.mint(walletA, 150 ether);

        // Keeper refreshes after the inflow → oracle incorporated the new state.
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        (HookDecision d, uint24 fee,) = harness.evaluateWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_CombinedStaleAndInflow_TakeStricterFee() external {
        token.mint(walletA, 100 ether);
        harness.updateKnownBalance(walletA, address(token));

        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0));

        harness.recordActivity(walletA);
        vm.warp(block.timestamp + 101);
        feed.setRound(int256(USD_1), block.timestamp);
        token.mint(walletA, 15_000 ether);

        // B mid ($1,000 swap) vs D high ($15,000 inbound) → 8%.
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 1_000 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_InflowHighBand_Charges8PercentEvenIfShareIsSmall() external {
        token.mint(walletA, 100_000 ether);
        harness.updateKnownBalance(walletA, address(token));
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        vm.warp(block.timestamp + 10);
        feed.setRound(int256(USD_1), block.timestamp);
        token.mint(walletA, 15_000 ether);

        (HookDecision d, uint24 fee,) = harness.evaluateWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_InflowBelowThreshold_DoesNotElevate() external {
        token.mint(walletA, 100 ether);
        harness.updateKnownBalance(walletA, address(token));
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        vm.warp(block.timestamp + 10);
        feed.setRound(int256(USD_1), block.timestamp);
        token.mint(walletA, 40 ether); // $40 < $1,000 → Floor D pass

        (HookDecision d,,) = harness.evaluateWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    function test_NeverWrittenScore_DoesNotEmitInflowHeuristic() external {
        token.mint(walletA, 100 ether);

        vm.recordLogs();
        (HookDecision d, uint24 fee,) = harness.evaluateLiveWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
        // Dust bag (< $1,000) does not arm Floor D. Only Mitigation A emits.
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function test_NeverWritten_LargeBag_SmallSwap_Charges8Percent() external {
        token.mint(walletA, 80_000 ether);
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 500 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_NeverWritten_PoolImpact_ElevatesDustTo8Percent() external {
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 500 ether, 2_001);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_NeverWritten_PoolImpact_RevertsMidBand() external {
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.UnscoredPoolImpactBlocked.selector, walletA, 2_001, 2_000)
        );
        harness.evaluate(walletA, address(token), 5_000 ether, 2_001);
    }

    function test_UnscoredBelowFeeThreshold_ReducedFee() external {
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 999 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_UnscoredAtFeeThreshold_StandardFee() external {
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 1_000 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_UnscoredBetweenThresholds_StandardFee() external {
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 5_000 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_UnscoredLowAndMidBands_AreDistinct() external {
        (HookDecision dLow, uint24 feeLow,) = harness.evaluate(walletA, address(token), 999 ether);
        (HookDecision dMid, uint24 feeMid,) = harness.evaluate(walletA, address(token), 1_000 ether);
        assertEq(uint8(dLow), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(uint8(dMid), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(feeLow, 300);
        assertEq(feeMid, 800);
        assertTrue(feeLow != feeMid);
    }

    function test_UnscoredAtRevertThreshold_RevertsWithUsdInError() external {
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.UnscoredMagnitudeBlocked.selector, walletA, USD_15000, USD_15000)
        );
        harness.evaluate(walletA, address(token), 15_000 ether);
    }

    function test_UnscoredAboveRevertThreshold_Reverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.UnscoredMagnitudeBlocked.selector, walletA, 30_000e8, USD_15000)
        );
        harness.evaluate(walletA, address(token), 30_000 ether);
    }

    function test_UnscoredMissingFeed_FailClosed() external {
        MockERC20 orphan = new MockERC20();
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.MagnitudeQuoteFailed.selector, address(orphan), harness.QUOTE_NO_FEED())
        );
        harness.evaluate(walletA, address(orphan), 1 ether);
    }

    function test_UnscoredStaleFeed_UsesLiveRound() external {
        feed.setRound(int256(USD_1), block.timestamp - 3_601);
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 1 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_UnscoredUnboundFeed_UsesLastFx() external {
        harness.evaluateLive(walletA, address(token), 1 ether);
        (uint256 price, uint64 quotedAt,,) = harness.lastFx(address(token));
        assertEq(price, USD_1);
        assertEq(quotedAt, uint64(block.timestamp));

        vm.prank(hookGovernor);
        harness.setPriceFeed(address(token), address(0));

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 500 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_UnscoredUnboundFeed_CacheExpired_FailClosed() external {
        harness.evaluateLive(walletA, address(token), 1 ether);
        vm.prank(hookGovernor);
        harness.setPriceFeed(address(token), address(0));
        vm.warp(block.timestamp + harness.MAX_PRICE_STALENESS() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AmlHookLogic.MagnitudeQuoteFailed.selector, address(token), harness.QUOTE_STALE_FEED()
            )
        );
        harness.evaluate(walletA, address(token), 1 ether);
    }

    function test_BadLivePrice_DoesNotOverwriteLastFx() external {
        harness.evaluateLive(walletA, address(token), 1 ether);
        feed.setRound(0, block.timestamp);
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 1 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
        (uint256 price,,,) = harness.lastFx(address(token));
        assertEq(price, USD_1);
    }

    function test_HotFx_IgnoresLivePriceMoveWithinThirtyMinutes() external {
        harness.evaluateLive(walletA, address(token), 20 ether);
        feed.setRound(int256(100e8), block.timestamp);
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 20 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_HotFx_RefreshesLiveAfterThirtyMinutes() external {
        harness.evaluateLive(walletA, address(token), 20 ether);
        vm.warp(block.timestamp + harness.FX_HOT_TTL() + 1);
        feed.setRound(int256(100e8), block.timestamp);
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 20 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_PublishedScoreZero_LargeSwapStillAllows() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 800 ether);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_UnscoredStructuring_SumExceedsRevertThreshold() external {
        harness.recordActivity(walletA, address(token), 10_000 ether);
        harness.recordActivity(walletA, address(token), 4_000 ether);
        assertEq(harness.windowVolume(walletA, address(token)), 14_000 ether);
        assertEq(harness.windowVolumeUsd(walletA), 14_000e8);
        assertEq(harness.dailyVolumeUsd(walletA), 14_000e8);

        // A looks at this swap only ($1,000). C blocks because prior 24h + this swap crosses $15,000.
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.DailyAggregationBlocked.selector, walletA, USD_15000, USD_15000)
        );
        harness.evaluate(walletA, address(token), 1_000 ether);
    }

    function test_UnscoredSixDecimalToken_UsesOnChainDecimalsForUsdBands() external {
        MockERC20 usdc = new MockERC20();
        usdc.setDecimals(6);
        vm.prank(hookGovernor);
        harness.setPriceFeed(address(usdc), address(feed));

        // 999 * 10^6 at $1 → dust band 3%. 1_000 * 10^6 → mid band 8%.
        (HookDecision dust, uint24 dustFee,) = harness.evaluate(walletA, address(usdc), 999 * 10 ** 6);
        assertEq(uint8(dust), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(dustFee, 300);

        (HookDecision mid, uint24 midFee,) = harness.evaluate(walletA, address(usdc), 1_000 * 10 ** 6);
        assertEq(uint8(mid), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(midFee, 800);

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.UnscoredMagnitudeBlocked.selector, walletA, USD_15000, USD_15000)
        );
        harness.evaluate(walletA, address(usdc), 15_000 * 10 ** 6);
    }

    function test_UnscoredStructuring_SumsUsdAcrossTokens() external {
        MockERC20 other = new MockERC20();
        vm.prank(hookGovernor);
        harness.setPriceFeed(address(other), address(feed));

        harness.recordActivity(walletA, address(token), 10_000 ether);
        harness.recordActivity(walletA, address(other), 5_000 ether);
        assertEq(harness.windowVolumeUsd(walletA), USD_15000);
        assertEq(harness.dailyVolumeUsd(walletA), USD_15000);

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.DailyAggregationBlocked.selector, walletA, USD_15000, USD_15000)
        );
        harness.evaluate(walletA, address(token), 0);
    }

    function test_UnscoredStructuring_HourResetDoesNotClearDaily() external {
        harness.recordActivity(walletA, address(token), 20_000 ether);
        vm.warp(block.timestamp + 1001); // past 1-hour B window; 24h C window still live
        feed.setRound(int256(USD_1), block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.DailyAggregationBlocked.selector, walletA, 20_020e8, USD_15000)
        );
        harness.evaluate(walletA, address(token), 20 ether);
    }

    function test_UnscoredStructuring_DailyResetClearsVolume() external {
        harness.recordActivity(walletA, address(token), 20_000 ether);
        vm.warp(block.timestamp + 24 hours + 1);
        feed.setRound(int256(USD_1), block.timestamp);
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 20 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_StalePoolImpact_ElevatesDustTo3Percent() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0));
        vm.warp(block.timestamp + 50);
        harness.recordActivity(walletA);
        vm.warp(block.timestamp + 100);
        feed.setRound(int256(USD_1), block.timestamp);

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 500 ether, 2_001);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_StalePoolImpact_ElevatesMidTo8Percent() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0));
        vm.warp(block.timestamp + 50);
        harness.recordActivity(walletA);
        vm.warp(block.timestamp + 100);
        feed.setRound(int256(USD_1), block.timestamp);

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 1_000 ether, 2_001);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_StalePoolImpact_HighBandStays8Percent() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0));
        vm.warp(block.timestamp + 50);
        harness.recordActivity(walletA);
        vm.warp(block.timestamp + 100);
        feed.setRound(int256(USD_1), block.timestamp);

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 15_000 ether, 2_001);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_PublishedDailyAggregation_FirstLargeSwapStillAllows() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 15_000 ether);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_PublishedDailyAggregation_BlocksWhenCrossed() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        harness.recordActivity(walletA, address(token), 10_000 ether);

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.DailyAggregationBlocked.selector, walletA, USD_15000, USD_15000)
        );
        harness.evaluate(walletA, address(token), 5_000 ether);
    }

    function test_SetDailyWindow_RestrictedToGovernor() external {
        assertEq(harness.dailyWindow(), 24 hours);

        vm.prank(hookGovernor);
        harness.setDailyWindow(12 hours);
        assertEq(harness.dailyWindow(), 12 hours);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setDailyWindow(24 hours);

        vm.startPrank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.DailyWindowInvalid.selector);
        harness.setDailyWindow(1 hours - 1);
        vm.expectRevert(AmlHookGovernance.DailyWindowInvalid.selector);
        harness.setDailyWindow(uint64(7 days) + 1);
        vm.stopPrank();
    }

    function test_GovernorCannotApplyUnscoredThresholds() external {
        vm.prank(hookGovernor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, hookGovernor));
        harness.applyUnscoredThresholds(2_000e8, 50_000e8);
    }

    function test_SetActivityWindow_RestrictedToGovernor() external {
        assertEq(harness.activityWindow(), 1000);

        vm.prank(hookGovernor);
        harness.setActivityWindow(2 hours);
        assertEq(harness.activityWindow(), 2 hours);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setActivityWindow(1 hours);
    }

    function test_SetActivityWindow_RevertsOutOfRange() external {
        vm.startPrank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.ActivityWindowInvalid.selector);
        harness.setActivityWindow(59);

        vm.expectRevert(AmlHookGovernance.ActivityWindowInvalid.selector);
        harness.setActivityWindow(uint64(7 days) + 1);
        vm.stopPrank();
    }

    function test_UpdateKnownBalance_SkipsWithinMinBaselineInterval() external {
        token.mint(walletA, 100 ether);
        harness.updateKnownBalance(walletA, address(token));
        uint256 ts = harness.lastKnownBalanceTimestamp(walletA, address(token));
        assertEq(harness.lastKnownBalance(walletA, address(token)), 100 ether);

        token.mint(walletA, 50 ether);
        harness.updateKnownBalance(walletA, address(token));
        assertEq(harness.lastKnownBalance(walletA, address(token)), 100 ether);
        assertEq(harness.lastKnownBalanceTimestamp(walletA, address(token)), ts);

        vm.warp(block.timestamp + harness.minBaselineInterval());
        harness.updateKnownBalance(walletA, address(token));
        assertEq(harness.lastKnownBalance(walletA, address(token)), 150 ether);
    }

    function test_PreviewSwap_MatchesEvaluate() external {
        token.mint(walletA, 1_000 ether);
        (HookDecision d1, uint24 f1,) = harness.evaluate(walletA, address(token), 1_000 ether);
        (HookDecision d2, uint24 f2,) = harness.previewSwap(walletA, address(token), 1_000 ether);
        assertEq(uint8(d1), uint8(d2));
        assertEq(f1, f2);
    }

    function test_ObserveSwap_RecordsActivityAndIsGovernorOnly() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        token.mint(walletA, 1_000 ether);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        harness.observeSwap(walletA, address(token), 1_000 ether);

        vm.startPrank(hookGovernor);
        harness.syncBaseline(walletA, address(token));
        (HookDecision d,,) = harness.observeSwap(walletA, address(token), 1_000 ether);
        vm.stopPrank();

        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        (, uint32 ops,) = harness.poolActivity(walletA);
        assertEq(ops, 1);
        assertEq(harness.lastKnownBalance(walletA, address(token)), 1_000 ether);
    }

    // ── M-01: observeSwap must not inflate Floor C daily USD accumulator ──────

    function test_ObserveSwap_DoesNotInflateDailyUsd() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        token.mint(walletA, 20_000 ether);
        feed.setRound(int256(USD_1), block.timestamp);

        vm.startPrank(hookGovernor);
        harness.syncBaseline(walletA, address(token));
        // 20k USD via observeSwap — must not count toward Floor C.
        harness.observeSwap(walletA, address(token), 20_000 ether);
        vm.stopPrank();

        // A subsequent real-path evaluate should ALLOW (daily accumulator is zero).
        (HookDecision d,,) = harness.evaluate(walletA, address(token), 1 ether);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    // ── H-01: Floor B extra gate — stale wallet should be escalated even on opCount==0 ──

    function test_StalePoolImpact_ElevatesOnWindowBoundary_OpCountZero() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0));
        // Let staleness threshold elapse without any activity.
        vm.warp(block.timestamp + 200);
        feed.setRound(int256(USD_1), block.timestamp);

        // No activity recorded → operationCount == 0, but score is stale and pool impact high.
        // H-01 gives FEE_OVERRIDE/300 from RiskPolicy; Floor B extra (stale + poolImpact > threshold)
        // then hardens it to punitiveFeeBps=800.
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 500 ether, 2_001);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800); // punitiveFeeBps (Floor B extra: stale + poolImpactBps 2001 > threshold 2000).
    }

    // ── H-04: syncBaseline must revert when inflow outpaces oracle ────────────

    function test_SyncBaseline_RevertsWhenInflowAheadOfOracle() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        token.mint(walletA, 100 ether);

        // Seed baseline at T0 — oracle updatedAt == block.timestamp > 0.
        vm.prank(hookGovernor);
        harness.syncBaseline(walletA, address(token));

        // Inflow arrives after the baseline was written.
        vm.warp(block.timestamp + 2 hours);
        token.mint(walletA, 500 ether); // balance: 600 ether, oracle still at old timestamp.

        // Oracle has not been updated since baseline was written → should revert.
        // Capture view values before vm.prank so external calls don't consume the prank.
        uint64 oracleUpdatedAt = complianceOracle.getRisk(walletA).updatedAt;
        uint256 lastKnownTs = harness.lastKnownBalanceTimestamp(walletA, address(token));
        vm.prank(hookGovernor);
        vm.expectRevert(
            abi.encodeWithSelector(
                AmlHookLogic.BaselineAheadOfOracle.selector,
                walletA,
                address(token),
                oracleUpdatedAt,
                lastKnownTs
            )
        );
        harness.syncBaseline(walletA, address(token));
    }

    function test_SyncBaseline_AllowsAfterOracleRefresh() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        token.mint(walletA, 100 ether);
        vm.prank(hookGovernor);
        harness.syncBaseline(walletA, address(token));

        vm.warp(block.timestamp + 2 hours);
        token.mint(walletA, 500 ether);

        // Keeper re-scores after inflow — oracle.updatedAt > lastKnownBalanceTimestamp.
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 5, 0, address(0), 0, _scoreSigN(walletA, 5, 0, address(0), 0, 1));

        // Now syncBaseline should succeed.
        vm.prank(hookGovernor);
        harness.syncBaseline(walletA, address(token));
        assertEq(harness.lastKnownBalance(walletA, address(token)), 600 ether);
    }
}
