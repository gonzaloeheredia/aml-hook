// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {Roles} from "libraries/Roles.sol";
import {Helpers, HookPoolManagerStub} from "test/utils/Helpers.t.sol";

/// @notice AmlHook liquidity gate: a sanctioned wallet cannot enter or exit as a liquidity
///         provider. Sanctions only — no score/fee evaluation, no RiskPolicy consultation.
contract UnitAmlHookLiquidityTest is Helpers {
    PoolKey key;
    ModifyLiquidityParams addParams;
    ModifyLiquidityParams removeParams;

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager));
        riskPolicy = new RiskPolicy();
        hook = _deployHook(accessManager, sanctionRegistry, complianceOracle, riskPolicy);

        bytes4[] memory registrySelectors = new bytes4[](1);
        registrySelectors[0] = SanctionRegistry.setSanctioned.selector;
        _wireRole(accessManager, owner, address(sanctionRegistry), registrySelectors, Roles._REGISTRY_KEEPER, keeper);

        _wireHookGovernor();

        key = _buildKey(address(hook));
        addParams = _buildLiquidityParams(int256(1e18));
        removeParams = _buildLiquidityParams(-int256(1e18));
    }

    /*///////////////////////////////////////////////////////////////
                        BEFORE ADD LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function test_CleanWalletCanAddLiquidity() external {
        address sender = _bindTrustedSubject(walletC);

        bytes4 sel =
            manager.callBeforeAddLiquidity(IHooks(address(hook)), sender, key, addParams, "");
        assertEq(sel, hook.beforeAddLiquidity.selector);
    }

    function test_SanctionedWalletCannotAddLiquidity() external {
        vm.prank(keeper);
        sanctionRegistry.setSanctioned(walletA, true);
        address sender = _bindTrustedSubject(walletA);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletA));
        manager.callBeforeAddLiquidity(IHooks(address(hook)), sender, key, addParams, "");
    }

    function test_UntrustedRouterCannotAddLiquidity() external {
        vm.expectRevert(AmlHookLogic.MissingSwapSubject.selector);
        manager.callBeforeAddLiquidity(IHooks(address(hook)), router, key, addParams, "");
    }

    /*///////////////////////////////////////////////////////////////
                       BEFORE REMOVE LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function test_CleanWalletCanRemoveLiquidity() external {
        address sender = _bindTrustedSubject(walletC);

        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), sender, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    /// @dev The trap: a sanctioned wallet's position sits untouched — the call reverts, nothing
    ///      is transferred or confiscated, only withdrawal is blocked while the sanction stands.
    function test_SanctionedWalletCannotRemoveLiquidity() external {
        vm.prank(keeper);
        sanctionRegistry.setSanctioned(walletB, true);
        address sender = _bindTrustedSubject(walletB);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), sender, key, removeParams, "");
    }

    /// @dev The lift: once the registry no longer reports the wallet as sanctioned, the exact
    ///      same removal succeeds — no separate unlock step, no keeper action beyond delisting.
    function test_RemoveLiquidityUnlocksAfterSanctionLifted() external {
        vm.startPrank(keeper);
        sanctionRegistry.setSanctioned(walletB, true);
        address sender = _bindTrustedSubject(walletB);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), sender, key, removeParams, "");

        sanctionRegistry.setSanctioned(walletB, false);
        vm.stopPrank();

        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), sender, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    function test_UntrustedRouterCannotRemoveLiquidity() external {
        vm.expectRevert(AmlHookLogic.MissingSwapSubject.selector);
        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), router, key, removeParams, "");
    }

    /*///////////////////////////////////////////////////////////////
                                PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @dev The hook governor's emergency pause freezes liquidity moves the same way it freezes
    ///      swap evaluation — both are part of the same `_HOOK_GOVERNOR`-controlled stop.
    function test_PausedHookBlocksLiquidityMoves() external {
        address sender = _bindTrustedSubject(walletC);

        vm.prank(hookGovernor);
        hook.pause();

        vm.expectRevert();
        manager.callBeforeAddLiquidity(IHooks(address(hook)), sender, key, addParams, "");

        vm.expectRevert();
        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), sender, key, removeParams, "");
    }
}
