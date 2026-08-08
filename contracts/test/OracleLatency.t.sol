// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SanctionRegistry} from "../src/registries/SanctionRegistry.sol";
import {ComplianceOracle} from "../src/oracle/ComplianceOracle.sol";
import {RiskPolicy} from "../src/policy/RiskPolicy.sol";
import {HookDecision} from "../src/libraries/HookDecision.sol";
import {AmlHookLogic} from "../src/hooks/AmlHookLogic.sol";

import {AmlHookHarness} from "./AmlHookHarness.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Unit tests for whitepaper §3.8 oracle-latency mitigations.
contract OracleLatencyTest is Test {
    SanctionRegistry registry;
    ComplianceOracle oracle;
    RiskPolicy policy;
    AmlHookHarness hook;
    MockERC20 token;

    address keeper = address(0xBEEF);
    address wallet = address(0xC0FFEE);

    event LatencyMitigationApplied(
        address indexed wallet, bytes32 reason, uint24 feeBps, uint8 oracleScore
    );

    event InflowHeuristicTriggered(address indexed wallet, uint256 deltaBps, uint256 timestamp);

    function setUp() public {
        registry = new SanctionRegistry(address(this));
        oracle = new ComplianceOracle(address(this));
        policy = new RiskPolicy();
        // staleness=100, window=1000, maxOps=3
        hook = new AmlHookHarness(registry, oracle, policy, 100, 1000, 3);
        token = new MockERC20();
        oracle.setKeeper(keeper, true);
        vm.warp(1_000_000);
    }

    function test_UnsetScore_NotAllow() public {
        (HookDecision d, uint24 fee,) = hook.evaluate(wallet);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, hook.LATENCY_FEE_BPS());
    }

    function test_UnsetScore_EmitsMitigationReason() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit LatencyMitigationApplied(wallet, hook.REASON_SCORE_NEVER_WRITTEN(), 800, 0);
        hook.evaluateLive(wallet);
    }

    function test_WrittenZeroScore_Allows() public {
        vm.prank(keeper);
        oracle.updateScore(wallet, 0, 0, address(0), 0, "");
        (HookDecision d, uint24 fee,) = hook.evaluate(wallet);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_StaleWithoutPoolActivity_StillAllows() public {
        vm.prank(keeper);
        oracle.updateScore(wallet, 0, 0, address(0), 0, "");
        // Age past stalenessThreshold but wallet never swapped in this pool → no elevation.
        vm.warp(block.timestamp + 101);
        (HookDecision d,,) = hook.evaluate(wallet);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    function test_StaleWithPoolActivity_Elevates() public {
        vm.prank(keeper);
        oracle.updateScore(wallet, 10, 0, address(0), 0, ""); // updatedAt = 1_000_000
        vm.warp(block.timestamp + 50);
        hook.recordActivity(wallet); // opCount in window = 1
        vm.warp(block.timestamp + 100); // now = 1_000_150; age = 150 > 100 → stale

        (HookDecision d, uint24 fee,) = hook.evaluate(wallet);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        // Latency floor: 8% when keeper omitted feeBps
        assertEq(fee, policy.LATENCY_FEE_BPS());

        vm.expectEmit(true, false, false, true, address(hook));
        emit LatencyMitigationApplied(wallet, hook.REASON_STALE_WITH_POOL_ACTIVITY(), 800, 10);
        hook.evaluateLive(wallet);
    }

    function test_FreshScore_AllowsDespitePriorActivity() public {
        hook.recordActivity(wallet);
        vm.prank(keeper);
        oracle.updateScore(wallet, 0, 0, address(0), 0, ""); // fresh write after activity
        (HookDecision d,,) = hook.evaluate(wallet);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    function test_ActivityWindowCap_ElevatesOnNthOp() public {
        vm.prank(keeper);
        oracle.updateScore(wallet, 0, 0, address(0), 0, "");

        hook.recordActivity(wallet);
        hook.recordActivity(wallet);
        hook.recordActivity(wallet);
        (, uint32 ops,) = hook.poolActivity(wallet);
        assertEq(ops, 3);

        (HookDecision d, uint24 fee,) = hook.evaluate(wallet);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_ActivityWindowResets() public {
        vm.prank(keeper);
        oracle.updateScore(wallet, 0, 0, address(0), 0, "");
        hook.recordActivity(wallet);
        hook.recordActivity(wallet);
        hook.recordActivity(wallet);

        vm.warp(block.timestamp + 1001); // past activityWindow=1000
        (HookDecision d,,) = hook.evaluate(wallet);
        // Window expired → operationCount 0; stale alone does not elevate → ALLOW
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    function test_RevertBand_NotSoftenedByMitigations() public {
        vm.prank(keeper);
        oracle.updateScore(wallet, 100, 0, wallet, 0, "");
        vm.expectRevert();
        hook.evaluate(wallet);
    }

    function test_FeeOverrideFromPolicy_NotDoubleChanged() public {
        vm.prank(keeper);
        oracle.updateScore(wallet, 65, 1, wallet, 300, "");
        (HookDecision d, uint24 fee,) = hook.evaluate(wallet);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_SetStalenessThreshold_OnlyOwner() public {
        hook.setStalenessThreshold(200);
        assertEq(hook.stalenessThreshold(), 200);
        vm.prank(address(0xDEAD));
        vm.expectRevert(AmlHookLogic.NotOwner.selector);
        hook.setStalenessThreshold(50);
    }

    function test_InflowAboveThreshold_WithStaleOracle_Elevates() public {
        // Baseline: wallet holds 100, oracle wrote score 0 at that time.
        token.mint(wallet, 100 ether);
        hook.updateKnownBalance(wallet, address(token));
        uint256 baselineTs = block.timestamp;

        vm.prank(keeper);
        oracle.updateScore(wallet, 0, 0, address(0), 0, "");
        assertEq(uint256(oracle.getRisk(wallet).updatedAt), baselineTs);

        // Large inflow after baseline; oracle not refreshed → floor.
        vm.warp(block.timestamp + 10);
        token.mint(wallet, 150 ether); // delta = 150 / 250 = 6000 bps > 5000

        (HookDecision d, uint24 fee,) = hook.evaluateWithToken(wallet, address(token));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, policy.LATENCY_FEE_BPS());

        vm.expectEmit(true, false, false, true, address(hook));
        emit InflowHeuristicTriggered(wallet, 6000, block.timestamp);
        hook.evaluateLiveWithToken(wallet, address(token));
    }

    function test_InflowAboveThreshold_WithFreshOracle_Allows() public {
        token.mint(wallet, 100 ether);
        hook.updateKnownBalance(wallet, address(token));

        vm.warp(block.timestamp + 10);
        token.mint(wallet, 150 ether);

        // Keeper refreshes after the inflow → oracle incorporated the new state.
        vm.prank(keeper);
        oracle.updateScore(wallet, 0, 0, address(0), 0, "");

        (HookDecision d, uint24 fee,) = hook.evaluateWithToken(wallet, address(token));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_CombinedStaleAndInflow_SingleFloor() public {
        token.mint(wallet, 100 ether);
        hook.updateKnownBalance(wallet, address(token));

        vm.prank(keeper);
        oracle.updateScore(wallet, 10, 0, address(0), 0, "");

        hook.recordActivity(wallet);
        vm.warp(block.timestamp + 101); // stale
        token.mint(wallet, 150 ether); // significant inflow; scoreUpdatedAt <= baseline

        (HookDecision d, uint24 fee,) = hook.evaluateWithToken(wallet, address(token));
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, policy.LATENCY_FEE_BPS());
    }

    function test_InflowBelowThreshold_DoesNotElevate() public {
        token.mint(wallet, 100 ether);
        hook.updateKnownBalance(wallet, address(token));
        vm.prank(keeper);
        oracle.updateScore(wallet, 0, 0, address(0), 0, "");

        vm.warp(block.timestamp + 10);
        token.mint(wallet, 40 ether); // delta = 40/140 ≈ 2857 bps < 5000

        (HookDecision d,,) = hook.evaluateWithToken(wallet, address(token));
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }
}
