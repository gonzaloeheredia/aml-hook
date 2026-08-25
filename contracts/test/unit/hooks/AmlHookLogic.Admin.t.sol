// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {AmlHookGovernance} from "contracts/hooks/AmlHookGovernance.sol";
import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {MultisigAggregation, MultisigType} from "libraries/WalletSubject.sol";
import {FeeBps} from "libraries/FeeBps.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {AmlHookHarness} from "./AmlHookHarness.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @notice Remaining AmlHookLogic governor / constructor / view surfaces.
contract UnitAmlHookLogicAdminTest is Helpers {
    AmlHookHarness harness;
    MockERC20 token;
    MockAggregatorV3 feed;

    function setUp() public {
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        harness = new AmlHookHarness(
            address(accessManager), sanctionRegistry, complianceOracle, riskPolicy, 0, 0
        );
        token = new MockERC20();

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory hookSelectors = new bytes4[](11);
        hookSelectors[0] = AmlHookGovernance.setMinBaselineInterval.selector;
        hookSelectors[1] = AmlHookGovernance.setPriceFeed.selector;
        hookSelectors[2] = AmlHookGovernance.setPriceStalenessThreshold.selector;
        hookSelectors[3] = AmlHookGovernance.pause.selector;
        hookSelectors[4] = AmlHookGovernance.unpause.selector;
        hookSelectors[5] = AmlHookGovernance.setTrustedRouter.selector;
        hookSelectors[6] = AmlHookGovernance.setStalenessThreshold.selector;
        hookSelectors[7] = AmlHookLogic.observeSwap.selector;
        hookSelectors[8] = AmlHookGovernance.setDailyWindow.selector;
        hookSelectors[9] = AmlHookGovernance.setTrustedMultisig.selector;
        hookSelectors[10] = AmlHookGovernance.setMultisigAggregation.selector;
        _wireRole(accessManager, owner, address(harness), hookSelectors, Roles._HOOK_GOVERNOR, hookGovernor);

        feed = new MockAggregatorV3();
        feed.setRound(1e8, block.timestamp);
        vm.prank(hookGovernor);
        harness.setPriceFeed(address(token), address(feed));
    }

    function test_Constructor_ZeroArgsSeedDefaults() external view {
        assertEq(harness.stalenessThreshold(), harness.DEFAULT_STALENESS());
        assertEq(harness.activityWindow(), harness.DEFAULT_ACTIVITY_WINDOW());
        assertEq(harness.dailyWindow(), harness.DEFAULT_DAILY_WINDOW());
        assertEq(harness.unscoredFeeThreshold(), harness.DEFAULT_USD_FEE_THRESHOLD());
        assertEq(harness.unscoredRevertThreshold(), harness.DEFAULT_USD_REVERT_THRESHOLD());
        assertEq(harness.proportionalFeeBps(), FeeBps.PROPORTIONAL);
        assertEq(harness.punitiveFeeBps(), FeeBps.PUNITIVE);
        assertEq(harness.poolImpactThresholdBps(), harness.DEFAULT_POOL_IMPACT_THRESHOLD_BPS());
        assertEq(harness.priceStalenessThreshold(), harness.DEFAULT_PRICE_STALENESS());
        assertEq(harness.inflowThresholdBps(), 5000);
        assertEq(harness.minBaselineInterval(), 1 hours);
        assertEq(uint8(harness.multisigAggregation()), uint8(MultisigAggregation.ALL_CLEAN));
        assertEq(address(harness.sanctionRegistry()), address(sanctionRegistry));
        assertEq(address(harness.complianceOracle()), address(complianceOracle));
        assertEq(address(harness.riskPolicy()), address(riskPolicy));
    }

    function test_Constructor_RejectsStalenessAboveMax() external {
        uint256 tooHigh = harness.MAX_STALENESS() + 1;
        vm.expectRevert(AmlHookGovernance.StalenessThresholdTooHigh.selector);
        new AmlHookHarness(
            address(accessManager),
            sanctionRegistry,
            complianceOracle,
            riskPolicy,
            tooHigh,
            3600
        );
    }

    function test_Constructor_RejectsInvalidActivityWindow() external {
        vm.expectRevert(AmlHookGovernance.ActivityWindowInvalid.selector);
        new AmlHookHarness(address(accessManager), sanctionRegistry, complianceOracle, riskPolicy, 300, 1);
    }

    function test_SetMinBaselineInterval_GovernorOnly() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setMinBaselineInterval(2 hours);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.BaselineIntervalZero.selector);
        harness.setMinBaselineInterval(0);

        vm.prank(hookGovernor);
        harness.setMinBaselineInterval(2 hours);
        assertEq(harness.minBaselineInterval(), 2 hours);
    }

    function test_SetPriceStalenessThreshold_GovernorOnly() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setPriceStalenessThreshold(120);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.PriceStalenessThresholdInvalid.selector);
        harness.setPriceStalenessThreshold(0);

        uint256 tooHigh = harness.MAX_PRICE_STALENESS() + 1;
        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.PriceStalenessThresholdInvalid.selector);
        harness.setPriceStalenessThreshold(tooHigh);

        vm.prank(hookGovernor);
        harness.setPriceStalenessThreshold(120);
        assertEq(harness.priceStalenessThreshold(), 120);
    }

    function test_SetPriceFeed_CanClearBinding() external {
        assertTrue(address(harness.priceFeeds(address(token))) != address(0));
        vm.prank(hookGovernor);
        harness.setPriceFeed(address(token), address(0));
        assertEq(address(harness.priceFeeds(address(token))), address(0));
    }

    function test_Pause_BlocksEvaluateAndUnpauseRestores() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 0, 0, address(0), 0, _scoreSig(walletA, 0, 0));

        vm.prank(hookGovernor);
        harness.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        harness.evaluate(walletA);

        vm.prank(hookGovernor);
        harness.unpause();
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA);
        assertEq(uint8(d), uint8(HookDecision.ALLOW));
        assertEq(fee, 0);
    }

    function test_WindowVolumeGetters_StartAtZeroThenAccumulate() external {
        assertEq(harness.windowVolume(walletA, address(token)), 0);
        assertEq(harness.windowVolumeUsd(walletA), 0);
        assertEq(harness.dailyVolumeUsd(walletA), 0);

        harness.recordActivity(walletA, address(token), 500 ether);

        assertEq(harness.windowVolume(walletA, address(token)), 500 ether);
        assertEq(harness.windowVolumeUsd(walletA), 500e8);
        assertEq(harness.dailyVolumeUsd(walletA), 500e8);
        (uint64 windowStart, uint32 ops, uint64 lastSwapAt) = harness.poolActivity(walletA);
        assertEq(ops, 1);
        assertEq(windowStart, uint64(block.timestamp));
        assertEq(lastSwapAt, uint64(block.timestamp));
    }

    function test_TrustedRouterMapping_Toggles() external {
        assertFalse(harness.trustedRouters(router));
        vm.prank(hookGovernor);
        harness.setTrustedRouter(router, true);
        assertTrue(harness.trustedRouters(router));
        vm.prank(hookGovernor);
        harness.setTrustedRouter(router, false);
        assertFalse(harness.trustedRouters(router));
    }

    function test_SetDailyWindow_GovernorOnlyAndBounds() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setDailyWindow(12 hours);

        uint64 belowMin = harness.MIN_DAILY_WINDOW() - 1;
        uint64 aboveMax = harness.MAX_DAILY_WINDOW() + 1;
        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.DailyWindowInvalid.selector);
        harness.setDailyWindow(belowMin);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.DailyWindowInvalid.selector);
        harness.setDailyWindow(aboveMax);

        vm.prank(hookGovernor);
        harness.setDailyWindow(12 hours);
        assertEq(harness.dailyWindow(), 12 hours);
    }

    function test_SetTrustedMultisig_GovernorOnlyAndRejectsZero() external {
        address safe = makeAddr("safe");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setTrustedMultisig(safe, MultisigType.GNOSIS_SAFE, true);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.MissingSwapSubject.selector);
        harness.setTrustedMultisig(address(0), MultisigType.GNOSIS_SAFE, true);

        vm.prank(hookGovernor);
        vm.expectRevert(AmlHookGovernance.MissingSwapSubject.selector);
        harness.setTrustedMultisig(safe, MultisigType.NONE, true);

        vm.prank(hookGovernor);
        harness.setTrustedMultisig(safe, MultisigType.GNOSIS_SAFE, true);
        (bool trusted, MultisigType kind) = harness.trustedMultisigs(safe);
        assertTrue(trusted);
        assertEq(uint8(kind), uint8(MultisigType.GNOSIS_SAFE));

        vm.prank(hookGovernor);
        harness.setTrustedMultisig(safe, MultisigType.GNOSIS_SAFE, false);
        (trusted, kind) = harness.trustedMultisigs(safe);
        assertFalse(trusted);
        assertEq(uint8(kind), uint8(MultisigType.NONE));
    }

    function test_SetMultisigAggregation_GovernorOnly() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.setMultisigAggregation(MultisigAggregation.ANY_CLEAN);

        vm.prank(hookGovernor);
        harness.setMultisigAggregation(MultisigAggregation.ANY_CLEAN);
        assertEq(uint8(harness.multisigAggregation()), uint8(MultisigAggregation.ANY_CLEAN));
    }
}
