// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {IComplianceOracle} from "interfaces/oracles/IComplianceOracle.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {AmlHookHarness} from "../unit/hooks/AmlHookHarness.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

contract IntegrationAmlStackTest is Helpers {
    AmlHookHarness harness;

    event SwapObserved(
        address indexed wallet,
        uint8 score,
        HookDecision decision,
        uint24 feeBps,
        uint8 hopDistance,
        address origin
    );

    function setUp() public {
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager));
        riskPolicy = new RiskPolicy();
        // stalenessThreshold=300s, activityWindow=3600s, maxOps=3
        harness =
            new AmlHookHarness(address(accessManager), sanctionRegistry, complianceOracle, riskPolicy, 300, 3600, 3);

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory registrySelectors = new bytes4[](1);
        registrySelectors[0] = SanctionRegistry.setSanctioned.selector;
        _wireRole(accessManager, owner, address(sanctionRegistry), registrySelectors, Roles._REGISTRY_KEEPER, keeper);
    }

    function _seedClean(address wallet) internal {
        vm.prank(keeper);
        complianceOracle.updateScore(wallet, 0, 0, address(0), 0, "");
    }

    function test_CleanWalletAllows_WhenKeeperWroteZero() external {
        _seedClean(walletC);
        (HookDecision d, uint24 fee,) = harness.evaluate(walletC);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_UnsetRisk_ElevatesToFeeOverride() external {
        // Never written → not ALLOW (oracle latency mitigation).
        (HookDecision d, uint24 fee,) = harness.evaluate(walletC);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_ExploitSourceReverts() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, "");

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.WalletBlocked.selector, walletA, uint8(100), "SCORE_REVERT_BAND")
        );
        harness.evaluate(walletA);
    }

    function test_BoundaryAllow30() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletC, 30, 0, address(0), 30, "");
        (HookDecision d, uint24 fee,) = harness.evaluate(walletC);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_BoundaryFeeOverride31() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 31, 1, walletA, 500, "");
        (HookDecision d, uint24 fee,) = harness.evaluate(walletB);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 500);
    }

    function test_BoundaryRevert71() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 71, 0, walletA, 0, "");
        vm.expectRevert();
        harness.evaluate(walletA);
    }

    function test_EmitSwapObserved() external {
        IComplianceOracle.WalletRisk memory risk = IComplianceOracle.WalletRisk({
            score: 42,
            hopDistance: 2,
            origin: walletA,
            feeBps: 300,
            updatedAt: uint64(block.timestamp)
        });
        vm.expectEmit(true, false, false, true, address(harness));
        emit SwapObserved(walletC, 42, HookDecision.FEE_OVERRIDE, 300, 2, walletA);
        harness.observe(walletC, HookDecision.FEE_OVERRIDE, 300, risk);
    }

    function test_OneHopFeeOverrideUsesOracleFee() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, "");

        (HookDecision d, uint24 fee,) = harness.evaluate(walletB);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_TwoHopFeeOverrideUsesOracleFee() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletC, 42, 2, walletA, 300, "");

        (HookDecision d, uint24 fee,) = harness.evaluate(walletC);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_FeeOverridePrefersOracleFeeOverFallback() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 300, "");

        (HookDecision d, uint24 fee,) = harness.evaluate(walletB);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_SanctionHitBeforeScore() external {
        vm.prank(keeper);
        sanctionRegistry.setSanctioned(walletB, true);
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 0, 0, address(0), 0, "");

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        harness.evaluate(walletB);
    }

    function test_EvaluateReturnsRiskSnapshot() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, "");
        (HookDecision d, uint24 fee, IComplianceOracle.WalletRisk memory risk) = harness.evaluate(walletB);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
        assertEq(risk.score, 65);
        assertEq(risk.feeBps, 800);
        assertEq(risk.origin, walletA);
    }
}
