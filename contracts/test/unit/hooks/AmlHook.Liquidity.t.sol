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

        bytes4[] memory registrySelectors = new bytes4[](3);
        registrySelectors[0] = SanctionRegistry.setSanctioned.selector;
        registrySelectors[1] = SanctionRegistry.commitSanction.selector;
        registrySelectors[2] = SanctionRegistry.revealSanction.selector;
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
        _sanction(sanctionRegistry, keeper, walletA);
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
        _sanction(sanctionRegistry, keeper, walletB);
        address sender = _bindTrustedSubject(walletB);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), sender, key, removeParams, "");
    }

    /// @dev The lift: once the registry no longer reports the wallet as sanctioned, the exact
    ///      same removal succeeds — no separate unlock step, no keeper action beyond delisting.
    function test_RemoveLiquidityUnlocksAfterSanctionLifted() external {
        _sanction(sanctionRegistry, keeper, walletB);
        address sender = _bindTrustedSubject(walletB);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), sender, key, removeParams, "");

        vm.prank(keeper);
        sanctionRegistry.setSanctioned(walletB, false);

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

    /// @dev pause() is a pool-wide emergency switch, not a targeted control. It still stops the
    ///      swap path, but neither liquidity gate listens to it: a clean wallet keeps depositing
    ///      while the hook is paused, exactly as it keeps withdrawing.
    function test_PausedHookStillAllowsCleanAddLiquidity() external {
        address sender = _bindTrustedSubject(walletC);

        vm.prank(hookGovernor);
        hook.pause();

        bytes4 sel =
            manager.callBeforeAddLiquidity(IHooks(address(hook)), sender, key, addParams, "");
        assertEq(sel, hook.beforeAddLiquidity.selector);
    }

    /// @dev A pause must never trap capital LPs already committed. A clean wallet's withdrawal
    ///      keeps working while the hook is paused.
    function test_PausedHookStillAllowsCleanRemoveLiquidity() external {
        address sender = _bindTrustedSubject(walletC);

        vm.prank(hookGovernor);
        hook.pause();

        bytes4 sel =
            manager.callBeforeRemoveLiquidity(IHooks(address(hook)), sender, key, removeParams, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    /// @dev Pausing is not a way to bypass the sanctions gate either way. Targeting a specific
    ///      wallet is SanctionRegistry's job, not pause()'s, and the two stay independent.
    function test_PausedHookStillBlocksSanctionedAddLiquidity() external {
        _sanction(sanctionRegistry, keeper, walletB);
        address sender = _bindTrustedSubject(walletB);

        vm.prank(hookGovernor);
        hook.pause();

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        manager.callBeforeAddLiquidity(IHooks(address(hook)), sender, key, addParams, "");
    }

    /// @dev Same independence, on the withdrawal side.
    function test_PausedHookStillBlocksSanctionedRemoveLiquidity() external {
        _sanction(sanctionRegistry, keeper, walletB);
        address sender = _bindTrustedSubject(walletB);

        vm.prank(hookGovernor);
        hook.pause();

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        manager.callBeforeRemoveLiquidity(IHooks(address(hook)), sender, key, removeParams, "");
    }

    /// @dev pause() still stops the swap path — this feature only removed it from the two
    ///      liquidity gates, it did not remove the governor's ability to stop swaps.
    function test_PausedHookStillBlocksSwaps() external {
        address sender = _bindTrustedSubject(walletC);

        vm.prank(hookGovernor);
        hook.pause();

        vm.expectRevert();
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, _buildParams(), "");
    }
}
