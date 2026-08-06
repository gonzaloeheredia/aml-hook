// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SanctionRegistry} from "../src/registries/SanctionRegistry.sol";
import {ComplianceOracle} from "../src/oracle/ComplianceOracle.sol";
import {RiskPolicy} from "../src/policy/RiskPolicy.sol";
import {HookDecision} from "../src/libraries/HookDecision.sol";
import {AmlHookLogic} from "../src/hooks/AmlHookLogic.sol";
import {IComplianceOracle} from "../src/interfaces/IComplianceOracle.sol";
import {AmlHookHarness} from "./AmlHookHarness.sol";

contract AmlStackTest is Test {
    SanctionRegistry registry;
    ComplianceOracle oracle;
    RiskPolicy policy;
    AmlHookHarness hook;

    address keeper = address(0xBEEF);
    address walletA = address(0xA11CE);
    address walletB = address(0xB0B);
    address walletC = address(0xC0FFEE);

    event SwapObserved(
        address indexed wallet,
        uint8 score,
        HookDecision decision,
        uint24 feeBps,
        uint8 hopDistance,
        address origin
    );

    function setUp() public {
        registry = new SanctionRegistry(address(this));
        oracle = new ComplianceOracle(address(this));
        policy = new RiskPolicy();
        // maxScoreAge=300s, activityWindow=3600s, maxOps=3
        hook = new AmlHookHarness(registry, oracle, policy, 300, 3600, 3);
        oracle.setKeeper(keeper, true);
    }

    function _seedClean(address wallet) internal {
        vm.prank(keeper);
        oracle.updateScore(wallet, 0, 0, address(0), 0, "");
    }

    function test_CleanWalletAllows_WhenKeeperWroteZero() public {
        _seedClean(walletC);
        (HookDecision d, uint24 fee,) = hook.evaluate(walletC);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_UnsetRisk_ElevatesToFeeOverride() public {
        // Never written → not ALLOW (oracle latency mitigation).
        (HookDecision d, uint24 fee,) = hook.evaluate(walletC);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_ExploitSourceReverts() public {
        vm.prank(keeper);
        oracle.updateScore(walletA, 100, 0, walletA, 0, "");

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.WalletBlocked.selector, walletA, uint8(100), "SCORE_REVERT_BAND")
        );
        hook.evaluate(walletA);
    }

    function test_BoundaryAllow30() public {
        vm.prank(keeper);
        oracle.updateScore(walletC, 30, 0, address(0), 30, "");
        (HookDecision d, uint24 fee,) = hook.evaluate(walletC);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_BoundaryFeeOverride31() public {
        vm.prank(keeper);
        oracle.updateScore(walletB, 31, 1, walletA, 500, "");
        (HookDecision d, uint24 fee,) = hook.evaluate(walletB);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 500);
    }

    function test_BoundaryRevert71() public {
        vm.prank(keeper);
        oracle.updateScore(walletA, 71, 0, walletA, 0, "");
        vm.expectRevert();
        hook.evaluate(walletA);
    }

    function test_EmitSwapObserved() public {
        IComplianceOracle.WalletRisk memory risk = IComplianceOracle.WalletRisk({
            score: 42,
            hopDistance: 2,
            origin: walletA,
            feeBps: 300,
            updatedAt: uint64(block.timestamp)
        });
        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletC, 42, HookDecision.FEE_OVERRIDE, 300, 2, walletA);
        hook.observe(walletC, HookDecision.FEE_OVERRIDE, 300, risk);
    }

    function test_OneHopFeeOverrideUsesOracleFee() public {
        vm.prank(keeper);
        oracle.updateScore(walletB, 65, 1, walletA, 800, "");

        (HookDecision d, uint24 fee,) = hook.evaluate(walletB);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_TwoHopFeeOverrideUsesOracleFee() public {
        vm.prank(keeper);
        oracle.updateScore(walletC, 42, 2, walletA, 300, "");

        (HookDecision d, uint24 fee,) = hook.evaluate(walletC);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_FeeOverridePrefersOracleFeeOverFallback() public {
        vm.prank(keeper);
        oracle.updateScore(walletB, 65, 1, walletA, 300, "");

        (HookDecision d, uint24 fee,) = hook.evaluate(walletB);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_SanctionHitBeforeScore() public {
        registry.setSanctioned(walletB, true);
        vm.prank(keeper);
        oracle.updateScore(walletB, 0, 0, address(0), 0, "");

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        hook.evaluate(walletB);
    }

    function test_EvaluateReturnsRiskSnapshot() public {
        vm.prank(keeper);
        oracle.updateScore(walletB, 65, 1, walletA, 800, "");
        (HookDecision d, uint24 fee, IComplianceOracle.WalletRisk memory risk) = hook.evaluate(walletB);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
        assertEq(risk.score, 65);
        assertEq(risk.feeBps, 800);
        assertEq(risk.origin, walletA);
    }
}
