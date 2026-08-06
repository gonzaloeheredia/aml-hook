// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SanctionRegistry} from "../src/registries/SanctionRegistry.sol";
import {ComplianceOracle} from "../src/oracle/ComplianceOracle.sol";
import {RiskPolicy} from "../src/policy/RiskPolicy.sol";
import {HookDecision} from "../src/libraries/HookDecision.sol";
import {AmlHookLogic} from "../src/hooks/AmlHookLogic.sol";

import {AmlHookHarness} from "./AmlHookHarness.sol";

/// @notice Unit tests for whitepaper §3.8 oracle-latency mitigations.
contract OracleLatencyTest is Test {
    SanctionRegistry registry;
    ComplianceOracle oracle;
    RiskPolicy policy;
    AmlHookHarness hook;

    address keeper = address(0xBEEF);
    address wallet = address(0xC0FFEE);

    event LatencyMitigationApplied(
        address indexed wallet, bytes32 reason, uint24 feeBps, uint8 oracleScore
    );

    function setUp() public {
        registry = new SanctionRegistry(address(this));
        oracle = new ComplianceOracle(address(this));
        policy = new RiskPolicy();
        // maxAge=100, window=1000, maxOps=3
        hook = new AmlHookHarness(registry, oracle, policy, 100, 1000, 3);
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
        // Age past maxScoreAge but wallet never swapped in this pool → no elevation.
        vm.warp(block.timestamp + 101);
        (HookDecision d,,) = hook.evaluate(wallet);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
    }

    function test_StaleWithPoolActivity_Elevates() public {
        vm.prank(keeper);
        oracle.updateScore(wallet, 10, 0, address(0), 0, ""); // updatedAt = 1_000_000
        vm.warp(block.timestamp + 50);
        hook.recordActivity(wallet); // lastSwapAt = 1_000_050
        vm.warp(block.timestamp + 100); // now = 1_000_150; age = 150 > 100 → stale
        // lastSwapAt (1_000_050) > updatedAt (1_000_000) → activity since write

        (HookDecision d, uint24 fee,) = hook.evaluate(wallet);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);

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

        // maxOpsInWindow = 3 → elevate when opCount >= 3 already recorded
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
        // Window expired → opCount treated as 0 for mitigation
        (HookDecision d,,) = hook.evaluate(wallet);
        // Score may be stale (age > 100) but no activity since write in the sense...
        // updatedAt=1e6, lastSwapAt was ~1e6, after warp lastSwapAt still old.
        // Stale? age = 1001 > 100 yes. Activity since? lastSwapAt > updatedAt?
        // If all records happened same second as write, lastSwapAt ≈ updatedAt, not >
        // After 3 records without warp, lastSwapAt == updatedAt (same block/time).
        // So stale+activity may be false; activity window reset → ALLOW.
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
        assertEq(fee, 300); // keeper fee preserved; mitigations only elevate ALLOW
    }
}
