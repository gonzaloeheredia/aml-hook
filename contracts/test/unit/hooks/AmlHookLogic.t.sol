// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {AmlHookHarness} from "./AmlHookHarness.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @notice AmlHookLogic §3.8 oracle-latency mitigations (unset / stale / inflow / activity cap).
contract UnitAmlHookLogicTest is Helpers {
    AmlHookHarness harness;
    MockERC20 token;
    MockAggregatorV3 feed;

    uint256 internal constant USD_1 = 1e8;
    uint256 internal constant USD_1000 = 1_000e8;
    uint256 internal constant USD_25000 = 25_000e8;

    event LatencyMitigationApplied(
        address indexed wallet, bytes32 reason, uint24 feeBps, uint8 oracleScore
    );

    event InflowHeuristicTriggered(address indexed wallet, uint256 deltaBps, uint256 timestamp);

    function setUp() public {
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        // staleness=100, window=1000, maxOps=3
        harness = new AmlHookHarness(address(accessManager), sanctionRegistry, complianceOracle, riskPolicy, 100, 1000, 3);
        token = new MockERC20();

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory hookSelectors = new bytes4[](9);
        hookSelectors[0] = AmlHookLogic.setStalenessThreshold.selector;
        hookSelectors[1] = AmlHookLogic.setInflowThresholdBps.selector;
        hookSelectors[2] = AmlHookLogic.setTrustedRouter.selector;
        hookSelectors[3] = AmlHookLogic.setUnscoredThresholds.selector;
        hookSelectors[4] = AmlHookLogic.setPriceFeed.selector;
        hookSelectors[5] = AmlHookLogic.setPriceStalenessThreshold.selector;
        hookSelectors[6] = AmlHookLogic.setActivityWindow.selector;
        hookSelectors[7] = AmlHookLogic.observeSwap.selector;
        hookSelectors[8] = AmlHookLogic.syncBaseline.selector;
        _wireRole(accessManager, owner, address(harness), hookSelectors, Roles._HOOK_GOVERNOR, hookGovernor);

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

    function test_StaleWithoutPoolActivity_StillAllows() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        // Age past stalenessThreshold but wallet never swapped in this pool → no elevation.
        vm.warp(block.timestamp + 101);
        (HookDecision d,,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    function test_StaleWithPoolActivity_Elevates() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0)); // updatedAt = 1_000_000
        vm.warp(block.timestamp + 50);
        harness.recordActivity(walletA); // opCount in window = 1
        vm.warp(block.timestamp + 100); // now = 1_000_150; age = 150 > 100 → stale

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        // Latency floor: 8% when keeper omitted feeBps
        assertEq(fee, riskPolicy.LATENCY_FEE_BPS());

        vm.expectEmit(true, false, false, true, address(harness));
        emit LatencyMitigationApplied(walletA, harness.REASON_STALE_WITH_POOL_ACTIVITY(), 800, 10);
        harness.evaluateLive(walletA);
    }

    function test_FreshScore_AllowsDespitePriorActivity() external {
        harness.recordActivity(walletA);
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0)); // fresh write after activity
        (HookDecision d,,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    function test_ActivityWindowCap_ElevatesOnNthOp() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        harness.recordActivity(walletA);
        harness.recordActivity(walletA);
        harness.recordActivity(walletA);
        (, uint32 ops,) = harness.poolActivity(walletA);
        assertEq(ops, 3);

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_ActivityWindowResets() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        harness.recordActivity(walletA);
        harness.recordActivity(walletA);
        harness.recordActivity(walletA);

        vm.warp(block.timestamp + 1001); // past activityWindow=1000
        (HookDecision d,,) = harness.evaluate(walletA);
        // Window expired → operationCount 0; stale alone does not elevate → ALLOW
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
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
        vm.expectRevert(AmlHookLogic.StalenessThresholdTooHigh.selector);
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
        vm.expectRevert(AmlHookLogic.InflowThresholdOutOfRange.selector);
        harness.setInflowThresholdBps(0);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookLogic.InflowThresholdOutOfRange.selector);
        harness.setInflowThresholdBps(99);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookLogic.InflowThresholdOutOfRange.selector);
        harness.setInflowThresholdBps(10_001);
    }

    function test_SetInflowThresholdBps_ChangesMitigationSensitivity() external {
        // Raise threshold above the 6000 bps inflow so the same mint no longer floors.
        vm.prank(hookGovernor);
        harness.setInflowThresholdBps(7000);

        token.mint(walletA, 100 ether);
        harness.updateKnownBalance(walletA, address(token));
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        vm.warp(block.timestamp + 10);
        token.mint(walletA, 150 ether); // 6000 bps < 7000 → no elevation

        (HookDecision d,,) = harness.evaluateWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    function test_InflowAboveThreshold_WithStaleOracle_Elevates() external {
        // Baseline: wallet holds 100, oracle wrote score 0 at that time.
        token.mint(walletA, 100 ether);
        harness.updateKnownBalance(walletA, address(token));
        uint256 baselineTs = block.timestamp;

        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));
        assertEq(uint256(complianceOracle.getRisk(walletA).updatedAt), baselineTs);

        // Large inflow after baseline; oracle not refreshed → floor.
        vm.warp(block.timestamp + 10);
        token.mint(walletA, 150 ether); // delta = 150 / 250 = 6000 bps > 5000

        (HookDecision d, uint24 fee,) = harness.evaluateWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, riskPolicy.LATENCY_FEE_BPS());

        vm.expectEmit(true, false, false, true, address(harness));
        emit InflowHeuristicTriggered(walletA, 6000, block.timestamp);
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

    function test_CombinedStaleAndInflow_SingleFloor() external {
        token.mint(walletA, 100 ether);
        harness.updateKnownBalance(walletA, address(token));

        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0));

        harness.recordActivity(walletA);
        vm.warp(block.timestamp + 101); // stale
        token.mint(walletA, 150 ether); // significant inflow; scoreUpdatedAt <= baseline

        (HookDecision d, uint24 fee,) = harness.evaluateWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, riskPolicy.LATENCY_FEE_BPS());
    }

    function test_InflowAtRevertThreshold_RevertsEvenIfShareIsSmall() external {
        // Whale: +$25,000 is 20% of $125,000 — below 50% relative floor, at the USD revert floor.
        token.mint(walletA, 100_000 ether);
        harness.updateKnownBalance(walletA, address(token));
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        vm.warp(block.timestamp + 10);
        feed.setRound(int256(USD_1), block.timestamp);
        token.mint(walletA, 25_000 ether);

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.InflowMagnitudeBlocked.selector, walletA, USD_25000, USD_25000)
        );
        harness.evaluateWithToken(walletA, address(token));
    }

    function test_InflowBelowThreshold_DoesNotElevate() external {
        token.mint(walletA, 100 ether);
        harness.updateKnownBalance(walletA, address(token));
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        vm.warp(block.timestamp + 10);
        token.mint(walletA, 40 ether); // delta = 40/140 ≈ 2857 bps < 5000

        (HookDecision d,,) = harness.evaluateWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    function test_NeverWrittenScore_DoesNotEmitInflowHeuristic() external {
        token.mint(walletA, 100 ether);

        vm.recordLogs();
        (HookDecision d, uint24 fee,) = harness.evaluateLiveWithToken(walletA, address(token));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
        // Mitigation A only (`LatencyMitigationApplied`). Inflow must not fire without a score/baseline.
        assertEq(vm.getRecordedLogs().length, 1);
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
            abi.encodeWithSelector(AmlHookLogic.UnscoredMagnitudeBlocked.selector, walletA, USD_25000, USD_25000)
        );
        harness.evaluate(walletA, address(token), 25_000 ether);
    }

    function test_UnscoredAboveRevertThreshold_Reverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.UnscoredMagnitudeBlocked.selector, walletA, 30_000e8, USD_25000)
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

    function test_UnscoredStaleFeed_FailClosed() external {
        feed.setRound(int256(USD_1), block.timestamp - 3_601);
        vm.expectRevert(
            abi.encodeWithSelector(
                AmlHookLogic.MagnitudeQuoteFailed.selector, address(token), harness.QUOTE_STALE_FEED()
            )
        );
        harness.evaluate(walletA, address(token), 1 ether);
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
        harness.recordActivity(walletA, address(token), 10_000 ether);
        harness.recordActivity(walletA, address(token), 4_000 ether);
        assertEq(harness.windowVolume(walletA, address(token)), 24_000 ether);
        assertEq(harness.windowVolumeUsd(walletA), 24_000e8);

        // Individual swap is small; window USD + this swap crosses $25,000.
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.UnscoredMagnitudeBlocked.selector, walletA, USD_25000, USD_25000)
        );
        harness.evaluate(walletA, address(token), 1_000 ether);
    }

    function test_UnscoredStructuring_SumsUsdAcrossTokens() external {
        MockERC20 other = new MockERC20();
        vm.prank(hookGovernor);
        harness.setPriceFeed(address(other), address(feed));

        harness.recordActivity(walletA, address(token), 10_000 ether);
        harness.recordActivity(walletA, address(other), 15_000 ether);
        assertEq(harness.windowVolumeUsd(walletA), USD_25000);

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.UnscoredMagnitudeBlocked.selector, walletA, USD_25000, USD_25000)
        );
        harness.evaluate(walletA, address(token), 0);
    }

    function test_UnscoredStructuring_WindowResetClearsVolume() external {
        harness.recordActivity(walletA, address(token), 20_000 ether);
        vm.warp(block.timestamp + 1001);
        feed.setRound(int256(USD_1), block.timestamp);
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 20 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_SetUnscoredThresholds_RestrictedToGovernor() external {
        vm.prank(hookGovernor);
        harness.setUnscoredThresholds(2_000e8, 50_000e8);
        assertEq(harness.unscoredFeeThreshold(), 2_000e8);
        assertEq(harness.unscoredRevertThreshold(), 50_000e8);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setUnscoredThresholds(1_000e8, 25_000e8);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookLogic.UnscoredThresholdsInvalid.selector);
        harness.setUnscoredThresholds(25_000e8, 25_000e8);
    }

    function test_SetActivityWindow_RestrictedToGovernor() external {
        assertEq(harness.activityWindow(), 1000);
        assertEq(harness.maxOpsInWindow(), 3);

        vm.prank(hookGovernor);
        harness.setActivityWindow(2 hours, 5);
        assertEq(harness.activityWindow(), 2 hours);
        assertEq(harness.maxOpsInWindow(), 5);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setActivityWindow(1 hours, 3);
    }

    function test_SetActivityWindow_RevertsOutOfRange() external {
        vm.startPrank(hookGovernor);
        vm.expectRevert(AmlHookLogic.ActivityWindowInvalid.selector);
        harness.setActivityWindow(59, 3);

        vm.expectRevert(AmlHookLogic.ActivityWindowInvalid.selector);
        harness.setActivityWindow(uint64(7 days) + 1, 3);

        vm.expectRevert(AmlHookLogic.MaxOpsInWindowInvalid.selector);
        harness.setActivityWindow(1 hours, 0);

        vm.expectRevert(AmlHookLogic.MaxOpsInWindowInvalid.selector);
        harness.setActivityWindow(1 hours, 101);
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
}
