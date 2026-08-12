// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {Helpers, HookPoolManagerStub} from "test/utils/Helpers.t.sol";

/// @notice AmlHook lifecycle: permissions, beforeSwap / afterSwap decision paths.
contract UnitAmlHookTest is Helpers {
    PoolKey key;
    SwapParams params;

    event SwapObserved(
        address indexed wallet,
        uint8 score,
        HookDecision decision,
        uint24 feeBps,
        uint8 hopDistance,
        address origin
    );

    function setUp() public {
        manager = new HookPoolManagerStub();
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));
        complianceOracle = new ComplianceOracle(address(accessManager));
        riskPolicy = new RiskPolicy();
        hook = _deployHook(accessManager, sanctionRegistry, complianceOracle, riskPolicy);

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory registrySelectors = new bytes4[](1);
        registrySelectors[0] = SanctionRegistry.setSanctioned.selector;
        _wireRole(accessManager, owner, address(sanctionRegistry), registrySelectors, Roles._REGISTRY_KEEPER, keeper);

        key = _buildKey(address(hook));
        params = _buildParams();
    }

    function test_PermissionsMatchAddress() external view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.beforeInitialize);
    }

    function test_CleanSwapAllowThenObserve() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletC, 0, 0, address(0), 0, "");
        bytes memory data = abi.encode(walletC);

        (bytes4 sel,, uint24 fee) =
            manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        assertEq(sel, hook.beforeSwap.selector);
        assertEq(fee, 0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletC, 0, HookDecision.ALLOW, 0, 0, address(0));

        manager.callAfterSwap(IHooks(address(hook)), router, key, params, BalanceDelta.wrap(0), data);
    }

    function test_UnsetScoreElevatesInBeforeSwap() external {
        // Pool keeps standard fee; risk differential is taken in afterSwap → FeeEscrow.
        bytes memory data = abi.encode(walletC);
        (,, uint24 fee) = manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        assertEq(fee, 0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletC, 0, HookDecision.FEE_OVERRIDE, 800, 0, address(0));
        manager.callAfterSwap(IHooks(address(hook)), router, key, params, BalanceDelta.wrap(0), data);
    }

    function test_FeeOverrideDoesNotOverridePoolLpFee() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, "");
        bytes memory data = abi.encode(walletB);

        (,, uint24 fee) = manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        assertEq(fee, 0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletB, 65, HookDecision.FEE_OVERRIDE, 800, 1, walletA);
        manager.callAfterSwap(IHooks(address(hook)), router, key, params, BalanceDelta.wrap(0), data);
    }

    function test_TwoHopCachesProportionalFeeForAfterSwap() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletC, 42, 2, walletA, 300, "");
        bytes memory data = abi.encode(walletC);

        (,, uint24 fee) = manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        assertEq(fee, 0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletC, 42, HookDecision.FEE_OVERRIDE, 300, 2, walletA);
        manager.callAfterSwap(IHooks(address(hook)), router, key, params, BalanceDelta.wrap(0), data);
    }

    function test_RevertBandRevertsInBeforeSwap() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, "");
        bytes memory data = abi.encode(walletA);

        vm.expectRevert();
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
    }

    function test_SanctionRevertsBeforeScore() external {
        vm.prank(keeper);
        sanctionRegistry.setSanctioned(walletB, true);
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 0, 0, address(0), 0, "");
        bytes memory data = abi.encode(walletB);

        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
    }

    function test_NonPoolManagerCannotCallBeforeSwap() external {
        bytes memory data = abi.encode(walletC);
        vm.prank(router);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(router, key, params, data);
    }

    function test_AfterSwapEmitsCachedDecision() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, "");
        bytes memory data = abi.encode(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletB, 65, HookDecision.FEE_OVERRIDE, 800, 1, walletA);
        manager.callAfterSwap(IHooks(address(hook)), router, key, params, BalanceDelta.wrap(0), data);
    }

    /// @dev Cache must name the screened wallet even if afterSwap hookData claims another subject.
    function test_AfterSwapWhenHookDataSubjectChanges() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, "");
        bytes memory beforeData = abi.encode(walletB);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, beforeData);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletB, 65, HookDecision.FEE_OVERRIDE, 800, 1, walletA);
        // Different / empty hookData must not retarget the trail.
        manager.callAfterSwap(IHooks(address(hook)), router, key, params, BalanceDelta.wrap(0), abi.encode(walletC));
    }

    /// @dev Cleared cache must not leak the prior subject into a second afterSwap in the same tx.
    function test_AfterSwapWhenCalledTwice() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, "");
        bytes memory data = abi.encode(walletB);

        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
        manager.callAfterSwap(IHooks(address(hook)), router, key, params, BalanceDelta.wrap(0), data);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(address(0), 0, HookDecision.ALLOW, 0, 0, address(0));
        manager.callAfterSwap(IHooks(address(hook)), router, key, params, BalanceDelta.wrap(0), data);
    }

    function test_EmptyHookDataRevertsNotRouter() external {
        vm.expectRevert(AmlHookLogic.MissingSwapSubject.selector);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, "");
    }

    function test_ZeroAddressHookDataReverts() external {
        bytes memory data = abi.encode(address(0));
        vm.expectRevert(AmlHookLogic.MissingSwapSubject.selector);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
    }
}
