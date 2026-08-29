// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {AmlHookGovernance} from "contracts/hooks/AmlHookGovernance.sol";
import {AmlHookGovernanceBase} from "contracts/hooks/AmlHookGovernanceBase.sol";
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

/// @notice COMPLIANCE_OFFICER propose / 48h confirm path for USD floors, pool-impact, and floor fees.
contract UnitAmlHookLogicComplianceParamsTest is HelpersCore {
    AmlHookHarness harness;
    MockERC20 token;
    MockAggregatorV3 feed;

    event PolicyParamProposed(string name, uint256 previousValue, uint256 newValue, address indexed actor);
    event PolicyParamScheduled(
        string name, uint256 previousValue, uint256 newValue, address indexed actor, uint48 readyAt
    );
    event PolicyParamConfirmed(string name, uint256 previousValue, uint256 newValue, address indexed actor);

    function setUp() public {
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        harness = new AmlHookHarness(
            address(accessManager), sanctionRegistry, complianceOracle, riskPolicy, 100, 1000
        );
        token = new MockERC20();

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory hookSelectors = new bytes4[](3);
        hookSelectors[0] = AmlHookGovernance.setPriceFeed.selector;
        hookSelectors[1] = AmlHookGovernance.setTrustedRouter.selector;
        hookSelectors[2] = AmlHookGovernance.setStalenessThreshold.selector;
        _wireRole(accessManager, owner, address(harness), hookSelectors, Roles._HOOK_GOVERNOR, hookGovernor);
        _wireComplianceOfficer(address(harness), uint32(48 hours));

        vm.warp(1_000_000);
        feed = new MockAggregatorV3();
        feed.setRound(1e8, block.timestamp);
        vm.startPrank(hookGovernor);
        harness.setPriceFeed(address(0), address(feed));
        harness.setPriceFeed(address(token), address(feed));
        vm.stopPrank();
    }

    function _confirm(bytes memory data) internal {
        vm.prank(complianceOfficer);
        accessManager.schedule(address(harness), data, 0);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(complianceOfficer);
        accessManager.execute(address(harness), data);
        feed.setRound(1e8, block.timestamp);
    }

    function test_OnlyComplianceOfficerCanPropose() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        harness.proposeUnscoredThresholds(2_000e8, 50_000e8);

        vm.prank(hookGovernor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, hookGovernor));
        harness.proposeUnscoredThresholds(2_000e8, 50_000e8);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        harness.proposePoolImpactThresholdBps(1);
    }

    function test_ProposeDoesNotChangeLiveState() external {
        vm.prank(complianceOfficer);
        harness.proposeUnscoredThresholds(2_000e8, 50_000e8);
        assertEq(harness.unscoredFeeThreshold(), 1_000e8);
        assertEq(harness.unscoredRevertThreshold(), 15_000e8);

        vm.prank(complianceOfficer);
        harness.proposePoolImpactThresholdBps(4_000);
        assertEq(harness.poolImpactThresholdBps(), 2_000);

        vm.prank(complianceOfficer);
        harness.proposeFloorFees(100, 2_000);
        assertEq(harness.proportionalFeeBps(), 300);
        assertEq(harness.punitiveFeeBps(), 800);
    }

    function test_ApplyBeforeDelayReverts() external {
        vm.prank(complianceOfficer);
        harness.proposeUnscoredThresholds(2_000e8, 50_000e8);

        bytes memory data = abi.encodeCall(AmlHookGovernance.applyUnscoredThresholds, (2_000e8, 50_000e8));
        vm.prank(complianceOfficer);
        accessManager.schedule(address(harness), data, 0);

        vm.prank(complianceOfficer);
        vm.expectRevert();
        accessManager.execute(address(harness), data);

        assertEq(harness.unscoredFeeThreshold(), 1_000e8);
    }

    function test_ConfirmUnscoredThresholdsAfter48Hours() external {
        vm.prank(complianceOfficer);
        harness.proposeUnscoredThresholds(2_000e8, 50_000e8);

        bytes memory data = abi.encodeCall(AmlHookGovernance.applyUnscoredThresholds, (2_000e8, 50_000e8));
        vm.prank(complianceOfficer);
        accessManager.schedule(address(harness), data, 0);
        vm.warp(block.timestamp + 48 hours);

        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamConfirmed(
            harness.PARAM_UNSCORED_FEE_THRESHOLD(), 1_000e8, 2_000e8, complianceOfficer
        );
        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamConfirmed(
            harness.PARAM_UNSCORED_REVERT_THRESHOLD(), 15_000e8, 50_000e8, complianceOfficer
        );
        vm.prank(complianceOfficer);
        accessManager.execute(address(harness), data);
        feed.setRound(1e8, block.timestamp);

        assertEq(harness.unscoredFeeThreshold(), 2_000e8);
        assertEq(harness.unscoredRevertThreshold(), 50_000e8);
    }

    function test_ProposeUnscoredThresholdsEmitsBothParams() external {
        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamProposed(
            harness.PARAM_UNSCORED_FEE_THRESHOLD(), 1_000e8, 2_000e8, complianceOfficer
        );
        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamProposed(
            harness.PARAM_UNSCORED_REVERT_THRESHOLD(), 15_000e8, 50_000e8, complianceOfficer
        );
        vm.prank(complianceOfficer);
        harness.proposeUnscoredThresholds(2_000e8, 50_000e8);
    }

    function test_ProposeEmitsScheduledReadyAt() external {
        uint48 readyAt = uint48(block.timestamp + 48 hours);
        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamProposed(
            harness.PARAM_UNSCORED_FEE_THRESHOLD(), 1_000e8, 2_000e8, complianceOfficer
        );
        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamProposed(
            harness.PARAM_UNSCORED_REVERT_THRESHOLD(), 15_000e8, 50_000e8, complianceOfficer
        );
        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamScheduled(
            harness.PARAM_UNSCORED_FEE_THRESHOLD(), 1_000e8, 2_000e8, complianceOfficer, readyAt
        );
        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamScheduled(
            harness.PARAM_UNSCORED_REVERT_THRESHOLD(), 15_000e8, 50_000e8, complianceOfficer, readyAt
        );
        vm.prank(complianceOfficer);
        harness.proposeUnscoredThresholds(2_000e8, 50_000e8);
    }

    function test_UnscoredFeeThresholdCannotGoBelowFatfMinimum() external {
        vm.prank(complianceOfficer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AmlHookGovernanceBase.UnscoredFeeThresholdBelowFatfMinimum.selector, 1_000e8 - 1, 1_000e8
            )
        );
        harness.proposeUnscoredThresholds(1_000e8 - 1, 15_000e8);
    }

    function test_UnscoredRevertMustExceedFee() external {
        vm.startPrank(complianceOfficer);
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookGovernanceBase.UnscoredRevertMustExceedFee.selector, 15_000e8, 15_000e8)
        );
        harness.proposeUnscoredThresholds(15_000e8, 15_000e8);

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookGovernanceBase.UnscoredRevertMustExceedFee.selector, 15_000e8, 14_999e8)
        );
        harness.proposeUnscoredThresholds(15_000e8, 14_999e8);
        vm.stopPrank();
    }

    function test_UnscoredRevertZeroIsRejected() external {
        vm.prank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(AmlHookGovernanceBase.UnscoredRevertMustExceedFee.selector, 1_000e8, 0));
        harness.proposeUnscoredThresholds(1_000e8, 0);
    }

    function test_PoolImpactHasNoNumericRange() external {
        vm.startPrank(complianceOfficer);
        harness.proposePoolImpactThresholdBps(0);
        harness.proposePoolImpactThresholdBps(20_000);
        harness.proposePoolImpactThresholdBps(type(uint256).max);
        vm.stopPrank();

        _confirm(abi.encodeCall(AmlHookGovernance.applyPoolImpactThresholdBps, (type(uint256).max)));
        assertEq(harness.poolImpactThresholdBps(), type(uint256).max);
    }

    function test_ConfirmPoolImpactEmitsActorAndValues() external {
        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamProposed(harness.PARAM_POOL_IMPACT_THRESHOLD_BPS(), 2_000, 4_000, complianceOfficer);
        vm.prank(complianceOfficer);
        harness.proposePoolImpactThresholdBps(4_000);

        bytes memory data = abi.encodeCall(AmlHookGovernance.applyPoolImpactThresholdBps, (4_000));
        vm.prank(complianceOfficer);
        accessManager.schedule(address(harness), data, 0);
        vm.warp(block.timestamp + 48 hours);

        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamConfirmed(harness.PARAM_POOL_IMPACT_THRESHOLD_BPS(), 2_000, 4_000, complianceOfficer);
        vm.prank(complianceOfficer);
        accessManager.execute(address(harness), data);
        feed.setRound(1e8, block.timestamp);
        assertEq(harness.poolImpactThresholdBps(), 4_000);
    }

    function test_FloorFeesRequirePunitiveGreaterThanProportional() external {
        vm.startPrank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(AmlHookGovernanceBase.PunitiveFeeMustExceedProportional.selector, 300, 300));
        harness.proposeFloorFees(300, 300);

        vm.expectRevert(abi.encodeWithSelector(AmlHookGovernanceBase.PunitiveFeeMustExceedProportional.selector, 800, 300));
        harness.proposeFloorFees(800, 300);
        vm.stopPrank();
    }

    function test_PunitiveFeeMayExceedMaxOverride() external {
        vm.prank(complianceOfficer);
        harness.proposeFloorFees(300, 2_500);
        _confirm(abi.encodeCall(AmlHookGovernance.applyFloorFees, (uint24(300), uint24(2_500))));
        assertEq(harness.proportionalFeeBps(), 300);
        assertEq(harness.punitiveFeeBps(), 2_500);
    }

    function test_ProportionalFeeMayBeZero() external {
        vm.prank(complianceOfficer);
        harness.proposeFloorFees(0, 800);
        _confirm(abi.encodeCall(AmlHookGovernance.applyFloorFees, (uint24(0), uint24(800))));
        assertEq(harness.proportionalFeeBps(), 0);
        assertEq(harness.punitiveFeeBps(), 800);
    }

    function test_LiveFloorFeesFlowThroughDecide() external {
        vm.prank(complianceOfficer);
        harness.proposeFloorFees(111, 2_222);
        _confirm(abi.encodeCall(AmlHookGovernance.applyFloorFees, (uint24(111), uint24(2_222))));

        token.mint(walletA, 500 ether);
        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 500 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 111);
    }

    function test_ApplyWithoutProposalReverts() external {
        bytes memory data = abi.encodeCall(AmlHookGovernance.applyFloorFees, (uint24(100), uint24(900)));
        vm.prank(complianceOfficer);
        accessManager.schedule(address(harness), data, 0);
        vm.warp(block.timestamp + 48 hours);
        vm.startPrank(complianceOfficer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AmlHookGovernanceBase.NoPendingPolicyParam.selector, harness.PARAM_PROPORTIONAL_FEE_BPS()
            )
        );
        accessManager.execute(address(harness), data);
        vm.stopPrank();
    }

    function test_ApplyMismatchedPendingReverts() external {
        vm.prank(complianceOfficer);
        harness.proposeFloorFees(100, 900);

        bytes memory data = abi.encodeCall(AmlHookGovernance.applyFloorFees, (uint24(200), uint24(900)));
        vm.prank(complianceOfficer);
        accessManager.schedule(address(harness), data, 0);
        vm.warp(block.timestamp + 48 hours);
        vm.startPrank(complianceOfficer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AmlHookGovernanceBase.PendingPolicyParamMismatch.selector, harness.PARAM_PROPORTIONAL_FEE_BPS()
            )
        );
        accessManager.execute(address(harness), data);
        vm.stopPrank();
    }

    function test_GovernorCannotApplyEvenAfterProposal() external {
        vm.prank(complianceOfficer);
        harness.proposeUnscoredThresholds(2_000e8, 50_000e8);

        vm.prank(hookGovernor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, hookGovernor));
        harness.applyUnscoredThresholds(2_000e8, 50_000e8);
    }

    function test_FatfMinimumIsAllowed_AndHasNoCeiling() external {
        vm.prank(complianceOfficer);
        harness.proposeUnscoredThresholds(1_000e8, 1_000e8 + 1);
        _confirm(abi.encodeCall(AmlHookGovernance.applyUnscoredThresholds, (1_000e8, 1_000e8 + 1)));
        assertEq(harness.unscoredFeeThreshold(), 1_000e8);
        assertEq(harness.unscoredRevertThreshold(), 1_000e8 + 1);

        vm.prank(complianceOfficer);
        harness.proposeUnscoredThresholds(1_000_000e8, 2_000_000e8);
        _confirm(abi.encodeCall(AmlHookGovernance.applyUnscoredThresholds, (1_000_000e8, 2_000_000e8)));
        assertEq(harness.unscoredFeeThreshold(), 1_000_000e8);
        assertEq(harness.unscoredRevertThreshold(), 2_000_000e8);
    }

    function test_ConfirmedUsdFloorsChangeEvaluateBands() external {
        (HookDecision beforeMid, uint24 beforeFee,) = harness.evaluate(walletA, address(token), 1_500 ether);
        assertEq(uint8(beforeMid), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(beforeFee, 800);

        vm.prank(complianceOfficer);
        harness.proposeUnscoredThresholds(2_000e8, 50_000e8);
        _confirm(abi.encodeCall(AmlHookGovernance.applyUnscoredThresholds, (2_000e8, 50_000e8)));

        (HookDecision afterMid, uint24 afterFee,) = harness.evaluate(walletA, address(token), 1_500 ether);
        assertEq(uint8(afterMid), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(afterFee, 300);

        (HookDecision stillAllowed, uint24 stillFee,) = harness.evaluate(walletA, address(token), 15_000 ether);
        assertEq(uint8(stillAllowed), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(stillFee, 800);

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.UnscoredMagnitudeBlocked.selector, walletA, 50_000e8, 50_000e8)
        );
        harness.evaluate(walletA, address(token), 50_000 ether);
    }

    function test_ConfirmedFloorFeesChangeUnscoredBands() external {
        vm.prank(complianceOfficer);
        harness.proposeFloorFees(50, 1_500);
        _confirm(abi.encodeCall(AmlHookGovernance.applyFloorFees, (uint24(50), uint24(1_500))));

        (HookDecision dust, uint24 dustFee,) = harness.evaluate(walletA, address(token), 500 ether);
        assertEq(uint8(dust), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(dustFee, 50);

        (HookDecision mid, uint24 midFee,) = harness.evaluate(walletA, address(token), 1_000 ether);
        assertEq(uint8(mid), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(midFee, 1_500);
        assertTrue(midFee > 1_000);
    }

    function test_ConfirmedPoolImpactZeroDisablesExtra() external {
        vm.prank(complianceOfficer);
        harness.proposePoolImpactThresholdBps(0);
        _confirm(abi.encodeCall(AmlHookGovernance.applyPoolImpactThresholdBps, (0)));

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 500 ether, 9_000);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_ConfirmedPoolImpactAboveTenThousandStillArms() external {
        vm.prank(complianceOfficer);
        harness.proposePoolImpactThresholdBps(12_000);
        _confirm(abi.encodeCall(AmlHookGovernance.applyPoolImpactThresholdBps, (12_000)));

        (HookDecision below, uint24 belowFee,) = harness.evaluate(walletA, address(token), 500 ether, 12_000);
        assertEq(uint8(below), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(belowFee, 300);

        (HookDecision above, uint24 aboveFee,) = harness.evaluate(walletA, address(token), 500 ether, 12_001);
        assertEq(uint8(above), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(aboveFee, 800);
    }

    function test_ConfirmedHighFloorMovesDailyAggregation() external {
        harness.recordActivity(walletA, address(token), 14_000 ether);

        vm.prank(complianceOfficer);
        harness.proposeUnscoredThresholds(1_000e8, 50_000e8);
        _confirm(abi.encodeCall(AmlHookGovernance.applyUnscoredThresholds, (1_000e8, 50_000e8)));

        (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), 1_000 ether);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 800);
    }

    function test_ProposeOverwriteThenConfirmLastValues() external {
        vm.startPrank(complianceOfficer);
        harness.proposeUnscoredThresholds(2_000e8, 20_000e8);
        harness.proposeUnscoredThresholds(3_000e8, 40_000e8);
        vm.stopPrank();

        _confirm(abi.encodeCall(AmlHookGovernance.applyUnscoredThresholds, (3_000e8, 40_000e8)));
        assertEq(harness.unscoredFeeThreshold(), 3_000e8);
        assertEq(harness.unscoredRevertThreshold(), 40_000e8);
    }

    function test_ProposeFloorFeesEmitsBothParams() external {
        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamProposed(harness.PARAM_PROPORTIONAL_FEE_BPS(), 300, 50, complianceOfficer);
        vm.expectEmit(true, false, false, true, address(harness));
        emit PolicyParamProposed(harness.PARAM_PUNITIVE_FEE_BPS(), 800, 1_500, complianceOfficer);
        vm.prank(complianceOfficer);
        harness.proposeFloorFees(50, 1_500);
    }
}
