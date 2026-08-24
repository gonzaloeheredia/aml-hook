// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {AmlHookHarness} from "./AmlHookHarness.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @notice Fuzz: hook evaluate matches RiskPolicy for published scores and never-scored USD bands.
contract UnitAmlHookLogicFuzzTest is Helpers {
    AmlHookHarness harness;
    MockERC20 token;
    MockAggregatorV3 feed;

    function setUp() public {
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        harness = new AmlHookHarness(
            address(accessManager), sanctionRegistry, complianceOracle, riskPolicy, 300, 3600, 3
        );
        token = new MockERC20();

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory hookSelectors = new bytes4[](4);
        hookSelectors[0] = AmlHookLogic.setPriceFeed.selector;
        hookSelectors[1] = AmlHookLogic.setStalenessThreshold.selector;
        hookSelectors[2] = AmlHookLogic.setInflowThresholdBps.selector;
        hookSelectors[3] = AmlHookLogic.setActivityWindow.selector;
        _wireRole(accessManager, owner, address(harness), hookSelectors, Roles._HOOK_GOVERNOR, hookGovernor);

        feed = new MockAggregatorV3();
        feed.setRound(1e8, block.timestamp);
        vm.startPrank(hookGovernor);
        harness.setPriceFeed(address(token), address(feed));
        harness.setPriceFeed(address(0), address(feed));
        vm.stopPrank();
    }

    function testFuzz_PublishedScore_EvaluateMatchesPolicy(address wallet, uint8 score, uint24 feeBps) external {
        score = uint8(bound(score, 0, 100));
        feeBps = uint24(bound(feeBps, 0, 1000));

        vm.prank(keeper);
        complianceOracle.updateScore(wallet, score, 0, address(0), feeBps, _scoreSig(wallet, score, feeBps));

        (HookDecision expectedDecision, uint24 expectedFee) = riskPolicy.decide(
            score,
            feeBps,
            false,
            0,
            false,
            false,
            0,
            0,
            harness.unscoredFeeThreshold(),
            harness.unscoredRevertThreshold(),
            harness.proportionalFeeBps(),
            harness.punitiveFeeBps()
        );

        if (expectedDecision == HookDecision.REVERT) {
            vm.expectRevert();
            harness.evaluate(wallet);
            return;
        }

        (HookDecision d, uint24 fee,) = harness.evaluate(wallet);
        assertEq(uint8(d), uint8(expectedDecision));
        assertEq(fee, expectedFee);
    }

    function testFuzz_NeverScoredUsdBands(uint256 amount) external {
        amount = bound(amount, 0, 50_000 ether);
        uint256 usd = amount / 1e10; // 18-dec token at $1 → USD-8

        if (usd >= harness.unscoredRevertThreshold()) {
            vm.expectRevert();
            harness.evaluate(walletA, address(token), amount);
            return;
        }

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), amount);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        if (usd < harness.unscoredFeeThreshold()) assertEq(fee, harness.proportionalFeeBps());
        else assertEq(fee, harness.punitiveFeeBps());
    }

    function testFuzz_GovernorSetters_RejectOutOfRange(uint256 staleness, uint256 inflow, uint64 window, uint32 maxOps)
        external
    {
        if (staleness == 0 || staleness > harness.MAX_STALENESS()) {
            vm.prank(hookGovernor);
            vm.expectRevert();
            harness.setStalenessThreshold(staleness);
        } else {
            vm.prank(hookGovernor);
            harness.setStalenessThreshold(staleness);
            assertEq(harness.stalenessThreshold(), staleness);
        }

        if (inflow < 100 || inflow > 10_000) {
            vm.prank(hookGovernor);
            vm.expectRevert(AmlHookLogic.InflowThresholdOutOfRange.selector);
            harness.setInflowThresholdBps(inflow);
        } else {
            vm.prank(hookGovernor);
            harness.setInflowThresholdBps(inflow);
            assertEq(harness.inflowThresholdBps(), inflow);
        }

        if (
            window < harness.MIN_ACTIVITY_WINDOW() || window > harness.MAX_ACTIVITY_WINDOW()
                || maxOps < harness.MIN_MAX_OPS_IN_WINDOW() || maxOps > harness.MAX_MAX_OPS_IN_WINDOW()
        ) {
            vm.prank(hookGovernor);
            vm.expectRevert();
            harness.setActivityWindow(window, maxOps);
        } else {
            vm.prank(hookGovernor);
            harness.setActivityWindow(window, maxOps);
            assertEq(harness.activityWindow(), window);
            assertEq(harness.maxOpsInWindow(), maxOps);
        }
    }

    function testFuzz_RecordActivity_AccumulatesUntilWindowElapses(uint8 n, uint256 amount) external {
        n = uint8(bound(n, 1, 8));
        amount = bound(amount, 1, 10 ether);

        uint256 expectedUsd;
        for (uint256 i; i < n; ++i) {
            harness.recordActivity(walletA, address(token), amount);
            expectedUsd += amount / 1e10;
        }

        (, uint32 ops,) = harness.poolActivity(walletA);
        assertEq(ops, n);
        assertEq(harness.windowVolume(walletA, address(token)), amount * n);
        assertEq(harness.windowVolumeUsd(walletA), expectedUsd);
        assertEq(harness.dailyVolumeUsd(walletA), expectedUsd);

        vm.warp(block.timestamp + harness.activityWindow());
        assertEq(harness.windowVolumeUsd(walletA), 0);
        assertEq(harness.dailyVolumeUsd(walletA), expectedUsd);
    }
}
