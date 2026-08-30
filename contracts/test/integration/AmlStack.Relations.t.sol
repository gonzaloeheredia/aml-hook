// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {AmlHook} from "contracts/hooks/AmlHook.sol";
import {AmlHookGovernance} from "contracts/hooks/AmlHookGovernance.sol";
import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {FeeEscrow} from "contracts/escrow/FeeEscrow.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {IComplianceOracle} from "interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "interfaces/policies/IRiskPolicy.sol";
import {IFeeEscrow} from "interfaces/escrow/IFeeEscrow.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {AmlHookHarness} from "../unit/hooks/AmlHookHarness.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockFeeToken} from "../../script/mocks/MockFeeToken.sol";
import {Helpers, HookPoolManagerStub} from "test/utils/Helpers.t.sol";

/// @notice Cross-module relations: L1 → L2 → L3 → hook → FeeEscrow, plus role isolation.
contract IntegrationAmlStackRelationsTest is Helpers {
    AmlHookHarness harness;
    MockERC20 token;
    MockFeeToken feeToken;
    FeeEscrow escrow;
    PoolKey key;
    SwapParams params;

    address fund = makeAddr("lpFund");
    address reserve = makeAddr("complianceReserve");

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        harness = new AmlHookHarness(
            address(accessManager), sanctionRegistry, complianceOracle, riskPolicy, 300, 3600
        );

        token = new MockERC20();
        feeToken = new MockFeeToken();
        escrow = new FeeEscrow(owner, address(feeToken), fund, reserve, owner);

        hook = _deployHook(
            accessManager, sanctionRegistry, complianceOracle, riskPolicy, IFeeEscrow(address(escrow))
        );
        vm.prank(owner);
        escrow.bootstrapDepositor(address(hook));
        vm.prank(owner);
        escrow.setAuditor(address(this), true);

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, oracleKeeper);

        bytes4[] memory registrySelectors = new bytes4[](1);
        registrySelectors[0] = SanctionRegistry.setSanctioned.selector;
        _wireRole(
            accessManager, owner, address(sanctionRegistry), registrySelectors, Roles._REGISTRY_KEEPER, registryKeeper
        );

        bytes4[] memory hookGov = new bytes4[](3);
        hookGov[0] = AmlHookGovernance.setPriceFeed.selector;
        hookGov[1] = AmlHookGovernance.setTrustedRouter.selector;
        hookGov[2] = AmlHookLogic.observeSwap.selector;
        _wireRole(accessManager, owner, address(harness), hookGov, Roles._HOOK_GOVERNOR, hookGovernor);
        _wireHookGovernor();
        _wireComplianceOfficer(address(harness), 0);
        _bindUsdFeeds();

        MockAggregatorV3 feed = new MockAggregatorV3();
        feed.setRound(1e8, block.timestamp);
        vm.startPrank(hookGovernor);
        AmlHookGovernance(address(harness)).setPriceFeed(address(token), address(feed));
        AmlHookGovernance(address(harness)).setPriceFeed(address(0), address(feed));
        vm.stopPrank();

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(feeToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    function test_L1SanctionWinsOverPublishedCleanScore() external {
        vm.prank(oracleKeeper);
        complianceOracle.updateScore(walletB, 0, 0, address(0), 0, _scoreSig(walletB, 0, 0));
        vm.prank(registryKeeper);
        sanctionRegistry.setSanctioned(walletB, true);

        IComplianceOracle.WalletRisk memory risk = complianceOracle.getRisk(walletB);
        assertEq(risk.score, 0);
        assertTrue(risk.updatedAt != 0);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        harness.evaluate(walletB);
    }

    function test_L2ScoreIsTheOnlyInputToL3ThroughTheHook() external {
        vm.prank(oracleKeeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 1, walletA, 800));

        (HookDecision policyDecision, uint24 policyFee) = _dec(_usd(65, 800, false, 0, false, 0, 0, 1_000e8, 15_000e8));
        (HookDecision hookDecision, uint24 hookFee, IComplianceOracle.WalletRisk memory risk) =
            harness.evaluate(walletB);

        assertEq(uint8(hookDecision), uint8(policyDecision));
        assertEq(hookFee, policyFee);
        assertEq(risk.score, 65);
        assertEq(risk.origin, walletA);
        assertEq(uint8(hookDecision), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(hookFee, 800);
    }

    function test_L2RevertBandBecomesHookWalletBlocked() external {
        vm.prank(oracleKeeper);
        complianceOracle.updateScore(walletA, 90, 0, walletA, 0, _scoreSig(walletA, 90, 0, walletA, 0));

        (HookDecision d,) = _dec(_in(90, 0));
        assertEq(uint8(d), uint8(HookDecision.REVERT));

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.WalletBlocked.selector, walletA, uint8(90), "SCORE_REVERT_BAND")
        );
        harness.evaluate(walletA);
    }

    function test_OracleKeeperCannotWriteSanctions() external {
        vm.prank(oracleKeeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, oracleKeeper));
        sanctionRegistry.setSanctioned(walletA, true);
    }

    function test_RegistryKeeperCannotWriteScores() external {
        vm.prank(registryKeeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, registryKeeper));
        complianceOracle.updateScore(walletA, 10, 0, address(0), 0, _scoreSig(walletA, 10, 0));
    }

    function test_GovernorCannotApplyPolicyKnobs() external {
        vm.prank(complianceOfficer);
        AmlHookGovernance(address(harness)).proposeFloorFees(10, 20);

        vm.prank(hookGovernor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, hookGovernor));
        AmlHookGovernance(address(harness)).applyFloorFees(10, 20);
    }

    function test_OfficerCannotRetuneGovernorKnobs() external {
        vm.prank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, complianceOfficer));
        AmlHookGovernance(address(harness)).setPriceFeed(address(token), address(0));
    }

    function test_FeeEscrowIsIndependentOfAccessManagerRoles() external {
        vm.prank(oracleKeeper);
        vm.expectRevert(FeeEscrow.NotDepositor.selector);
        escrow.deposit(walletA, address(feeToken), bytes32(uint256(1)), 1 ether);

        vm.prank(hookGovernor);
        vm.expectRevert(FeeEscrow.NotDepositor.selector);
        escrow.deposit(walletA, address(feeToken), bytes32(uint256(1)), 1 ether);

        assertEq(escrow.owner(), owner);
        assertTrue(escrow.depositors(address(hook)));
        assertFalse(escrow.depositors(oracleKeeper));
    }

    function test_FeeOverrideSwapDepositsDifferentialIntoEscrow() external {
        vm.prank(oracleKeeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 1, walletA, 800));
        address sender = _bindTrustedSubject(walletB);

        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");

        uint256 output = 1_000 ether;
        feeToken.mint(address(manager), output);
        BalanceDelta delta = toBalanceDelta(0, int128(int256(output)));

        manager.callAfterSwap(IHooks(address(hook)), sender, key, params, delta, "");

        IFeeEscrow.EscrowRecord memory rec = escrow.getEscrow(1);
        assertEq(rec.wallet, walletB);
        assertEq(rec.token, address(feeToken));
        assertGt(rec.amount, 0);
        assertEq(uint8(rec.status), uint8(IFeeEscrow.EscrowStatus.Active));
        assertEq(escrow.balances(walletB, address(feeToken)), rec.amount);
    }

    function test_AllowSwapDoesNotTouchEscrow() external {
        vm.prank(oracleKeeper);
        complianceOracle.updateScore(walletC, 0, 0, address(0), 0, _scoreSig(walletC, 0, 0));
        address sender = _bindTrustedSubject(walletC);

        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
        manager.callAfterSwap(IHooks(address(hook)), sender, key, params, toBalanceDelta(0, 1e18), "");

        assertEq(escrow.nextEscrowId(), 1);
        assertEq(escrow.balances(walletC, address(feeToken)), 0);
    }

    function testFuzz_PublishedScore_HookMatchesPolicy(uint8 score, uint24 feeBps) external {
        score = uint8(bound(score, 0, 100));
        feeBps = uint24(bound(feeBps, 0, 1000));

        vm.prank(oracleKeeper);
        complianceOracle.updateScore(walletC, score, 1, walletA, feeBps, _scoreSig(walletC, score, 1, walletA, feeBps));

        (HookDecision expected, uint24 expectedFee) = _dec(
            _fees(
                _usd(score, feeBps, false, 0, false, 0, 0, harness.unscoredFeeThreshold(), harness.unscoredRevertThreshold()),
                harness.proportionalFeeBps(),
                harness.punitiveFeeBps()
            )
        );

        if (expected == HookDecision.REVERT) {
            vm.expectRevert();
            harness.evaluate(walletC);
        } else {
            (HookDecision d, uint24 fee,) = harness.evaluate(walletC);
            assertEq(uint8(d), uint8(expected));
            assertEq(fee, expectedFee);
        }
    }

    function testFuzz_NeverScoredMagnitude_HookAndPolicyAgree(uint256 amount) external {
        amount = bound(amount, 0, 40_000 ether);
        uint256 usd = amount / 1e10;

        (HookDecision expected, uint24 expectedFee) = _dec(
            _fees(
                _usd(0, 0, false, 0, true, usd, 0, harness.unscoredFeeThreshold(), harness.unscoredRevertThreshold()),
                harness.proportionalFeeBps(),
                harness.punitiveFeeBps()
            )
        );

        if (expected == HookDecision.REVERT) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    AmlHookLogic.UnscoredMagnitudeBlocked.selector, walletA, usd, harness.unscoredRevertThreshold()
                )
            );
            harness.evaluate(walletA, address(token), amount);
        } else {
            (HookDecision d, uint24 fee,) = harness.evaluate(walletA, address(token), amount);
            assertEq(uint8(d), uint8(expected));
            assertEq(fee, expectedFee);
        }
    }

    function test_FloorC_PolicyAndHookAgree() external {
        vm.prank(oracleKeeper);
        complianceOracle.updateScore(walletC, 0, 0, address(0), 0, _scoreSig(walletC, 0, 0));

        vm.prank(hookGovernor);
        harness.recordActivity(walletC, address(token), 10_000 ether);

        IRiskPolicy.DecisionInput memory i = _fees(
            _usd(0, 0, false, 0, false, 0, 0, harness.unscoredFeeThreshold(), harness.unscoredRevertThreshold()),
            harness.proportionalFeeBps(),
            harness.punitiveFeeBps()
        );
        i.priorDailyUsd = 10_000e8;
        i.swapUsd = 5_000e8;
        IRiskPolicy.DecisionResult memory policy = _policy(i);
        assertEq(uint8(policy.decision), uint8(HookDecision.REVERT));
        assertEq(uint8(policy.revertKind), uint8(IRiskPolicy.RevertKind.DailyAggregation));

        vm.expectRevert(
            abi.encodeWithSelector(
                AmlHookLogic.DailyAggregationBlocked.selector, walletC, 15_000e8, harness.unscoredRevertThreshold()
            )
        );
        harness.evaluate(walletC, address(token), 5_000 ether);
    }

    function test_FloorB_StaleWithOps_HookMatchesPolicy() external {
        vm.prank(oracleKeeper);
        complianceOracle.updateScore(walletC, 0, 0, address(0), 0, _scoreSig(walletC, 0, 0));

        harness.recordActivity(walletC, address(token), 100 ether);
        vm.warp(block.timestamp + harness.stalenessThreshold() + 1);

        uint256 amount = 1_000 ether;
        uint256 assessedUsd = amount / 1e10 + harness.windowVolumeUsd(walletC);
        (HookDecision expected, uint24 expectedFee) = _dec(
            _fees(
                _usd(0, 0, true, 1, false, assessedUsd, 0, harness.unscoredFeeThreshold(), harness.unscoredRevertThreshold()),
                harness.proportionalFeeBps(),
                harness.punitiveFeeBps()
            )
        );

        (HookDecision d, uint24 fee,) = harness.evaluate(walletC, address(token), amount);
        assertEq(uint8(d), uint8(expected));
        assertEq(fee, expectedFee);
        assertEq(uint8(d), uint8(HookDecision.FEE_OVERRIDE));
        assertEq(fee, 300);
    }

    function test_LiquidityGateBlocksScoreRevertBandAndSanctions() external {
        vm.prank(oracleKeeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, _scoreSig(walletA, 100, 0, walletA, 0));

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.WalletBlocked.selector, walletA, uint8(100), "SCORE_REVERT_BAND")
        );
        manager.callBeforeAddLiquidity(
            IHooks(address(hook)), walletA, key, _buildLiquidityParams(int256(1e18)), ""
        );

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.WalletBlocked.selector, walletA, uint8(100), "SCORE_REVERT_BAND")
        );
        harness.evaluate(walletA);

        vm.prank(registryKeeper);
        sanctionRegistry.setSanctioned(walletA, true);
        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletA));
        manager.callBeforeAddLiquidity(
            IHooks(address(hook)), walletA, key, _buildLiquidityParams(int256(1e18)), ""
        );
    }

    function testFuzz_PreviewSwapAgreesWithEvaluateAcrossStack(uint8 score, uint256 amount) external {
        score = uint8(bound(score, 0, 70));
        amount = bound(amount, 0, 14_000 ether);
        vm.prank(oracleKeeper);
        complianceOracle.updateScore(walletC, score, 1, walletA, 300, _scoreSig(walletC, score, 1, walletA, 300));

        (HookDecision d1, uint24 f1,) = harness.evaluate(walletC, address(token), amount);
        (HookDecision d2, uint24 f2,) = harness.previewSwap(walletC, address(token), amount);
        assertEq(uint8(d1), uint8(d2));
        assertEq(f1, f2);
        assertTrue(d1 != HookDecision.REVERT);
    }
}
