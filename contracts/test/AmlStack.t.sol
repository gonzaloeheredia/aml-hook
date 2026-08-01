// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SanctionRegistry} from "../src/registries/SanctionRegistry.sol";
import {ComplianceOracle} from "../src/oracle/ComplianceOracle.sol";
import {RiskPolicy} from "../src/policy/RiskPolicy.sol";
import {HookDecision} from "../src/libraries/HookDecision.sol";
import {AmlHookLogic} from "../src/hooks/AmlHookLogic.sol";
import {IComplianceOracle} from "../src/interfaces/IComplianceOracle.sol";

/// @dev Concrete harness to exercise AmlHookLogic without Uniswap v4 BaseHook.
contract AmlHookHarness is AmlHookLogic {
    constructor(
        SanctionRegistry registry_,
        ComplianceOracle oracle_,
        RiskPolicy policy_
    ) AmlHookLogic(registry_, oracle_, policy_) {}

    function evaluate(address wallet)
        external
        view
        returns (HookDecision decision, uint24 feeBps, IComplianceOracle.WalletRisk memory risk)
    {
        return _evaluate(wallet);
    }

    function observe(
        address wallet,
        HookDecision decision,
        uint24 feeBps,
        IComplianceOracle.WalletRisk calldata risk
    ) external {
        _emitSwapObserved(wallet, decision, feeBps, risk);
    }
}

contract AmlStackTest is Test {
    SanctionRegistry registry;
    ComplianceOracle oracle;
    RiskPolicy policy;
    AmlHookHarness hook;

    address keeper = address(0xBEEF);
    address walletA = address(0xA11CE);
    address walletB = address(0xB0B);
    address walletC = address(0xC0FFEE);

    function setUp() public {
        registry = new SanctionRegistry(address(this));
        oracle = new ComplianceOracle(address(this));
        policy = new RiskPolicy();
        hook = new AmlHookHarness(registry, oracle, policy);

        oracle.setKeeper(keeper, true);
    }

    function test_CleanWalletAllows() public view {
        (HookDecision d, uint24 fee,) = hook.evaluate(walletC);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_ExploitSourceReverts() public {
        vm.prank(keeper);
        oracle.updateScore(walletA, 100, 0, walletA, "");

        vm.expectRevert();
        hook.evaluate(walletA);
    }

    function test_OneHopFeeOverridePunitive() public {
        vm.prank(keeper);
        oracle.updateScore(walletB, 65, 1, walletA, "");

        (HookDecision d, uint24 fee,) = hook.evaluate(walletB);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_TwoHopFeeOverrideProportional() public {
        vm.prank(keeper);
        oracle.updateScore(walletC, 42, 2, walletA, "");

        (HookDecision d, uint24 fee,) = hook.evaluate(walletC);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_SanctionHitBeforeScore() public {
        registry.setSanctioned(walletB, true);
        vm.prank(keeper);
        oracle.updateScore(walletB, 0, 0, address(0), "");

        vm.expectRevert();
        hook.evaluate(walletB);
    }
}
