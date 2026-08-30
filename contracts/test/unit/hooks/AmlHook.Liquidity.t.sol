// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {AmlHookGovernance} from "contracts/hooks/AmlHookGovernance.sol";
import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {AmlHookSettlement} from "contracts/hooks/AmlHookSettlement.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {FeeEscrow} from "contracts/escrow/FeeEscrow.sol";
import {ComplianceTreasury} from "contracts/treasury/ComplianceTreasury.sol";
import {IFeeEscrow} from "interfaces/escrow/IFeeEscrow.sol";
import {IComplianceTreasury} from "interfaces/treasury/IComplianceTreasury.sol";
import {Roles} from "libraries/Roles.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Helpers, HookPoolManagerStub} from "test/utils/Helpers.t.sol";

/// @notice LP gate: L1 + score ≥ 71 block add. Known 31–70 / never-scored A/C/D take in afterAdd.
///         Blocked remove seizes principal and fees into FeeEscrow 48h.
contract UnitAmlHookLiquidityTest is Helpers {
    PoolKey key;
    ModifyLiquidityParams addParams;
    ModifyLiquidityParams removeParams;
    MockERC20 token0;
    MockERC20 token1;
    FeeEscrow escrow;
    ComplianceTreasury treasury;
    address fund = address(0xF11D);

    event LiquiditySubjectResolved(address indexed sender, address indexed subject, bool viaTrustedRouter);
    event LiquidityObserved(
        address indexed wallet, uint8 score, HookDecision decision, bool seized, bool viaTrustedRouter
    );
    event LpExitSeized(
        uint256 indexed seizeId,
        address indexed wallet,
        bytes32 poolId,
        bytes32 positionKey,
        uint256 principal0,
        uint256 principal1,
        uint256 fee0,
        uint256 fee1
    );

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();

        token0 = new MockERC20();
        token1 = new MockERC20();
        treasury = new ComplianceTreasury(owner, owner);
        escrow = new FeeEscrow(owner, address(token0), fund, address(treasury), owner);
        vm.startPrank(owner);
        escrow.setAllowedFeeToken(address(token1), true);
        escrow.setComplianceSources(sanctionRegistry, complianceOracle);
        escrow.setAuditor(address(this), true);
        vm.stopPrank();

        hook = _deployHook(
            accessManager, sanctionRegistry, complianceOracle, riskPolicy, IFeeEscrow(address(escrow)), treasury
        );
        vm.startPrank(owner);
        escrow.bootstrapDepositor(address(hook));
        treasury.setHook(address(hook));
        treasury.setEscrow(address(escrow));
        vm.stopPrank();

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory registrySelectors = new bytes4[](3);
        registrySelectors[0] = SanctionRegistry.setSanctioned.selector;
        registrySelectors[1] = SanctionRegistry.commitSanction.selector;
        registrySelectors[2] = SanctionRegistry.revealSanction.selector;
        _wireRole(accessManager, owner, address(sanctionRegistry), registrySelectors, Roles._REGISTRY_KEEPER, keeper);

        _wireHookGovernor();

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        addParams = _buildLiquidityParams(int256(1e18));
        removeParams = _buildLiquidityParams(-int256(1e18));
    }

    function test_CleanWalletCanAddLiquidity() external {
        bytes4 sel = manager.callBeforeAddLiquidity(IHooks(address(hook)), walletC, key, addParams, "");
        assertEq(sel, hook.beforeAddLiquidity.selector);
    }

    function test_SanctionedWalletCannotAddLiquidity() external {
        _sanction(sanctionRegistry, keeper, walletA);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletA));
        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletA, key, addParams, "");
    }

    function test_HighScoreWalletCannotAddLiquidity() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, _scoreSig(walletA, 100, 0, walletA, 0));

        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.WalletBlocked.selector, walletA, uint8(100), "SCORE_REVERT_BAND")
        );
        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletA, key, addParams, "");
    }

    function test_RouterMsgSenderIsLpSubjectOnAdd() external {
        _sanction(sanctionRegistry, keeper, walletA);
        address sender = _bindTrustedSubject(walletA);

        vm.expectEmit(true, true, false, true, address(hook));
        emit LiquiditySubjectResolved(sender, walletA, true);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletA));
        manager.callBeforeAddLiquidity(IHooks(address(hook)), sender, key, addParams, "");
    }

    function test_DirectSenderCanAddLiquidityWithoutTrustedRouter() external {
        bytes4 sel = manager.callBeforeAddLiquidity(IHooks(address(hook)), router, key, addParams, "");
        assertEq(sel, hook.beforeAddLiquidity.selector);
    }

    function test_CleanWalletCanRemoveLiquidity() external {
        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletC, key, removeParams, "");
        (bytes4 sel, BalanceDelta hookDelta) = manager.callAfterRemoveLiquidity(
            IHooks(address(hook)), walletC, key, removeParams, toBalanceDelta(1e18, 5e17), toBalanceDelta(1e16, 2e15), ""
        );
        assertEq(sel, hook.afterRemoveLiquidity.selector);
        assertEq(BalanceDelta.unwrap(hookDelta), 0);
    }

    function test_SanctionedRemoveSeizesPrincipalAndFees() external {
        _sanction(sanctionRegistry, keeper, walletB);

        uint256 prin0 = 1e18;
        uint256 prin1 = 5e17;
        uint256 fee0 = 1e16;
        uint256 fee1 = 2e15;
        token0.mint(address(manager), prin0 + fee0);
        token1.mint(address(manager), prin1 + fee1);

        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletB, key, removeParams, "");

        (bytes4 sel, BalanceDelta hookDelta) = manager.callAfterRemoveLiquidity(
            IHooks(address(hook)),
            walletB,
            key,
            removeParams,
            toBalanceDelta(int128(int256(prin0 + fee0)), int128(int256(prin1 + fee1))),
            toBalanceDelta(int128(int256(fee0)), int128(int256(fee1))),
            ""
        );
        assertEq(sel, hook.afterRemoveLiquidity.selector);
        assertTrue(BalanceDelta.unwrap(hookDelta) != 0);
        assertEq(token0.balanceOf(walletB), 0);
        assertEq(token1.balanceOf(walletB), 0);
        assertEq(treasury.balances(IComplianceTreasury.Account.LP_PRINCIPAL, address(token0)), 0);
        assertEq(treasury.balances(IComplianceTreasury.Account.LP_PRINCIPAL, address(token1)), 0);
        assertEq(escrow.getEscrow(1).amount, prin0);
        assertEq(uint8(escrow.getEscrow(1).kind), uint8(IFeeEscrow.EscrowKind.LpPrincipal));
        assertEq(escrow.getEscrow(2).amount, prin1);
        assertEq(uint8(escrow.getEscrow(3).kind), uint8(IFeeEscrow.EscrowKind.RiskFee));
        assertEq(escrow.getEscrow(3).amount, fee0);
        assertEq(escrow.getEscrow(4).amount, fee1);
        assertEq(uint8(escrow.getEscrow(1).status), uint8(IFeeEscrow.EscrowStatus.Active));
        assertEq(escrow.getEscrow(1).wallet, walletB);
    }

    function test_HighScoreWalletRemoveIsSeized() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, _scoreSig(walletA, 100, 0, walletA, 0));

        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletA, key, removeParams, "");
        (, BalanceDelta hookDelta) = manager.callAfterRemoveLiquidity(
            IHooks(address(hook)), walletA, key, removeParams, BalanceDelta.wrap(0), BalanceDelta.wrap(0), ""
        );
        assertEq(hook.nextSeizeId(), 2);
        assertEq(BalanceDelta.unwrap(hookDelta), 0);
    }

    function test_DirectSenderCanRemoveLiquidityWithoutTrustedRouter() external {
        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), router, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    function test_DelistedWalletCanRemoveLiquidity() external {
        _sanction(sanctionRegistry, keeper, walletB);

        vm.prank(keeper);
        sanctionRegistry.setSanctioned(walletB, false);

        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletB, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
        (, BalanceDelta hookDelta) = manager.callAfterRemoveLiquidity(
            IHooks(address(hook)), walletB, key, removeParams, toBalanceDelta(1, 1), toBalanceDelta(0, 0), ""
        );
        assertEq(BalanceDelta.unwrap(hookDelta), 0);
    }

    function test_PausedHookAllowsCleanAddLiquidity() external {
        vm.prank(hookGovernor);
        AmlHookGovernance(address(hook)).pause();

        bytes4 sel = manager.callBeforeAddLiquidity(IHooks(address(hook)), walletC, key, addParams, "");
        assertEq(sel, hook.beforeAddLiquidity.selector);
    }

    function test_PausedHookStillBlocksSanctionedAdd() external {
        _sanction(sanctionRegistry, keeper, walletA);
        vm.prank(hookGovernor);
        AmlHookGovernance(address(hook)).pause();

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletA));
        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletA, key, addParams, "");
    }

    function test_PausedHookStillAllowsCleanRemoveLiquidity() external {
        vm.prank(hookGovernor);
        AmlHookGovernance(address(hook)).pause();

        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletC, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    function test_PausedHookStillSeizesSanctionedRemove() external {
        _sanction(sanctionRegistry, keeper, walletB);

        vm.prank(hookGovernor);
        AmlHookGovernance(address(hook)).pause();

        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), walletB, key, removeParams, "");
        assertEq(hook.nextSeizeId(), 1);
    }

    function test_PausedHookStillBlocksSwaps() external {
        address sender = _bindTrustedSubject(walletC);

        vm.prank(hookGovernor);
        AmlHookGovernance(address(hook)).pause();

        vm.expectRevert();
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, _buildParams(), "");
    }

    function test_KnownMediumScoreAddEscrowsFullOverride() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletC, 42, 1, walletA, 300, _scoreSig(walletC, 42, 1, walletA, 300));

        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletC, key, addParams, "");
        uint256 paid = 1 ether;
        token0.mint(address(manager), paid);
        (, BalanceDelta hookDelta) = manager.callAfterAddLiquidity(
            IHooks(address(hook)),
            walletC,
            key,
            addParams,
            toBalanceDelta(-int128(int256(paid)), 0),
            toBalanceDelta(0, 0),
            ""
        );
        assertTrue(BalanceDelta.unwrap(hookDelta) != 0);
        assertEq(escrow.getEscrow(1).amount, (paid * 300) / 10_000);
        assertEq(uint8(escrow.getEscrow(1).kind), uint8(IFeeEscrow.EscrowKind.RiskFee));
        assertEq(escrow.getEscrow(1).wallet, walletC);
    }

    function test_NeverScoredLargeAddRevertsLikeFloorA() external {
        _bindUsdFeeds();
        vm.startPrank(hookGovernor);
        AmlHookGovernance(address(hook)).setPriceFeed(address(token0), address(usdFeed));
        AmlHookGovernance(address(hook)).setPriceFeed(address(token1), address(usdFeed));
        vm.stopPrank();

        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletE, key, addParams, "");
        vm.expectRevert(
            abi.encodeWithSelector(
                AmlHookLogic.UnscoredMagnitudeBlocked.selector, walletE, uint256(15_000e8), uint256(15_000e8)
            )
        );
        manager.callAfterAddLiquidity(
            IHooks(address(hook)),
            walletE,
            key,
            addParams,
            toBalanceDelta(-int128(int256(15_000 ether)), 0),
            toBalanceDelta(0, 0),
            ""
        );
    }

    function test_KnownCleanAddTakesNoFeeEvenIfStale() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletC, 0, 0, address(0), 0, _scoreSig(walletC, 0, 0, address(0), 0));
        vm.warp(block.timestamp + hook.stalenessThreshold() + 1);

        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletC, key, addParams, "");
        token0.mint(address(manager), 1 ether);
        (, BalanceDelta hookDelta) = manager.callAfterAddLiquidity(
            IHooks(address(hook)),
            walletC,
            key,
            addParams,
            toBalanceDelta(-int128(1e18), 0),
            toBalanceDelta(0, 0),
            ""
        );
        assertEq(BalanceDelta.unwrap(hookDelta), 0);
        assertEq(escrow.nextEscrowId(), 1);
    }

    function test_NeverScoredSmallAddTakesProportionalFee() external {
        _bindUsdFeeds();
        vm.startPrank(hookGovernor);
        AmlHookGovernance(address(hook)).setPriceFeed(address(token0), address(usdFeed));
        AmlHookGovernance(address(hook)).setPriceFeed(address(token1), address(usdFeed));
        vm.stopPrank();

        uint256 paid = 500 ether;
        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletE, key, addParams, "");
        token0.mint(address(manager), paid);
        (, BalanceDelta hookDelta) = manager.callAfterAddLiquidity(
            IHooks(address(hook)),
            walletE,
            key,
            addParams,
            toBalanceDelta(-int128(int256(paid)), 0),
            toBalanceDelta(0, 0),
            ""
        );
        assertTrue(BalanceDelta.unwrap(hookDelta) != 0);
        assertEq(escrow.getEscrow(1).amount, (paid * 300) / 10_000);
        assertEq(uint8(escrow.getEscrow(1).kind), uint8(IFeeEscrow.EscrowKind.RiskFee));
    }

    function test_NeverScoredAddsCrossing15kRevertLikeFloorC() external {
        _bindUsdFeeds();
        vm.startPrank(hookGovernor);
        AmlHookGovernance(address(hook)).setPriceFeed(address(token0), address(usdFeed));
        AmlHookGovernance(address(hook)).setPriceFeed(address(token1), address(usdFeed));
        vm.stopPrank();

        uint256 first = 10_000 ether;
        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletE, key, addParams, "");
        token0.mint(address(manager), first);
        manager.callAfterAddLiquidity(
            IHooks(address(hook)),
            walletE,
            key,
            addParams,
            toBalanceDelta(-int128(int256(first)), 0),
            toBalanceDelta(0, 0),
            ""
        );

        manager.callBeforeAddLiquidity(IHooks(address(hook)), walletE, key, addParams, "");
        vm.expectRevert(
            abi.encodeWithSelector(
                AmlHookLogic.DailyAggregationBlocked.selector, walletE, uint256(15_000e8), uint256(15_000e8)
            )
        );
        manager.callAfterAddLiquidity(
            IHooks(address(hook)),
            walletE,
            key,
            addParams,
            toBalanceDelta(-int128(int256(5_000 ether)), 0),
            toBalanceDelta(0, 0),
            ""
        );
    }
}
