// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {AmlHook} from "contracts/hooks/AmlHook.sol";
import {AmlHookLogic} from "contracts/hooks/AmlHookLogic.sol";
import {ComplianceOracle} from "contracts/oracles/ComplianceOracle.sol";
import {RiskPolicy} from "contracts/policies/RiskPolicy.sol";
import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {MockTrustedRouter} from "../../../script/mocks/MockTrustedRouter.sol";
import {MockGnosisSafe} from "test/mocks/MockGnosisSafe.sol";
import {Helpers, HookPoolManagerStub} from "test/utils/Helpers.t.sol";

/// @notice `_resolveWallet` / trusted-router subject resolution (`IMsgSender` only; hookData ignored).
contract UnitAmlHookResolveWalletTest is Helpers {
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
        complianceOracle = new ComplianceOracle(address(accessManager), _attestor());
        riskPolicy = new RiskPolicy();
        hook = _deployHook(accessManager, sanctionRegistry, complianceOracle, riskPolicy);

        bytes4[] memory oracleSelectors = new bytes4[](1);
        oracleSelectors[0] = ComplianceOracle.updateScore.selector;
        _wireRole(accessManager, owner, address(complianceOracle), oracleSelectors, Roles._ORACLE_KEEPER, keeper);

        bytes4[] memory registrySelectors = new bytes4[](3);
        registrySelectors[0] = SanctionRegistry.setSanctioned.selector;
        registrySelectors[1] = SanctionRegistry.commitSanction.selector;
        registrySelectors[2] = SanctionRegistry.revealSanction.selector;
        _wireRole(accessManager, owner, address(sanctionRegistry), registrySelectors, Roles._REGISTRY_KEEPER, keeper);

        _wireHookGovernor();

        key = _buildKey(address(hook));
        params = _buildParams();
    }

    function test_ResolveViaTrustedRouterWithoutHookData() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletC, 0, 0, address(0), 0, _scoreSig(walletC, 0, 0));
        MockTrustedRouter trusted = new MockTrustedRouter();
        trusted.setMsgSender(walletC);
        vm.prank(hookGovernor);
        hook.setTrustedRouter(address(trusted), true);

        (bytes4 sel,, uint24 fee) =
            manager.callBeforeSwap(IHooks(address(hook)), address(trusted), key, params, "");
        assertEq(sel, hook.beforeSwap.selector);
        assertEq(fee, 0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletC, 0, HookDecision.ALLOW, 0, 0, address(0));
        manager.callAfterSwap(
            IHooks(address(hook)), address(trusted), key, params, BalanceDelta.wrap(0), ""
        );
    }

    function test_ResolveViaTrustedRouterWithMatchingHookData() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 800));
        MockTrustedRouter trusted = new MockTrustedRouter();
        trusted.setMsgSender(walletB);
        vm.prank(hookGovernor);
        hook.setTrustedRouter(address(trusted), true);

        bytes memory data = abi.encode(walletB);
        (,, uint24 fee) =
            manager.callBeforeSwap(IHooks(address(hook)), address(trusted), key, params, data);
        // beforeSwap no longer sets lpFeeOverride; pool keeps standard fee.
        assertEq(fee, 0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletB, 65, HookDecision.FEE_OVERRIDE, 800, 1, walletA);
        manager.callAfterSwap(
            IHooks(address(hook)), address(trusted), key, params, BalanceDelta.wrap(0), data
        );
    }

    function test_ResolveViaTrustedRouterIgnoresMismatchedHookData() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletB, 65, 1, walletA, 800, _scoreSig(walletB, 65, 800));
        MockTrustedRouter trusted = new MockTrustedRouter();
        trusted.setMsgSender(walletB);
        vm.prank(hookGovernor);
        hook.setTrustedRouter(address(trusted), true);

        // hookData claims a different wallet; subject still comes from msgSender().
        bytes memory data = abi.encode(walletC);
        (,, uint24 fee) =
            manager.callBeforeSwap(IHooks(address(hook)), address(trusted), key, params, data);
        assertEq(fee, 0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit SwapObserved(walletB, 65, HookDecision.FEE_OVERRIDE, 800, 1, walletA);
        manager.callAfterSwap(
            IHooks(address(hook)), address(trusted), key, params, BalanceDelta.wrap(0), data
        );
    }

    function test_MissingSwapSubject_WithoutTrustedRouter() external {
        vm.expectRevert(AmlHookLogic.MissingSwapSubject.selector);
        manager.callBeforeSwap(IHooks(address(hook)), address(0xDEAD), key, params, "");
    }

    function test_TrustedRouter_RevertingMsgSender_DoesNotFallBackToHookData() external {
        MockTrustedRouter trusted = new MockTrustedRouter();
        trusted.setMsgSender(walletC);
        trusted.setRevertOnRead(true);
        vm.prank(hookGovernor);
        hook.setTrustedRouter(address(trusted), true);

        bytes memory data = abi.encode(walletC);
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.TrustedRouterSubjectFailed.selector, address(trusted))
        );
        manager.callBeforeSwap(IHooks(address(hook)), address(trusted), key, params, data);
    }

    function test_TrustedRouter_ZeroMsgSender_DoesNotFallBackToHookData() external {
        MockTrustedRouter trusted = new MockTrustedRouter();
        trusted.setMsgSender(address(0));
        vm.prank(hookGovernor);
        hook.setTrustedRouter(address(trusted), true);

        bytes memory data = abi.encode(walletC);
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.TrustedRouterSubjectFailed.selector, address(trusted))
        );
        manager.callBeforeSwap(IHooks(address(hook)), address(trusted), key, params, data);
    }

    function test_UntrustedRouter_HookDataIsIgnored() external {
        vm.prank(keeper);
        complianceOracle.updateScore(walletC, 0, 0, address(0), 0, _scoreSig(walletC, 0, 0));
        bytes memory data = abi.encode(walletC);
        vm.expectRevert(AmlHookLogic.MissingSwapSubject.selector);
        manager.callBeforeSwap(IHooks(address(hook)), router, key, params, data);
    }

    function test_SetTrustedRouter_RevertsForNonGovernor() external {
        MockTrustedRouter trusted = new MockTrustedRouter();
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, router));
        hook.setTrustedRouter(address(trusted), true);
    }

    /// @dev Manager admin is not the hook governor.
    function test_SetTrustedRouter_RevertsForManagerAdmin() external {
        MockTrustedRouter trusted = new MockTrustedRouter();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        hook.setTrustedRouter(address(trusted), true);
    }

    /// @dev Unwired hook selectors stay admin-only (forgotten wiring fails closed).
    function test_SetStalenessThreshold_WhenSelectorWasNeverWired() external {
        // Fresh stack: hook authority is accessManager but no target function role was set.
        AccessManager mgr = new AccessManager(owner);
        SanctionRegistry reg = new SanctionRegistry(address(mgr));
        ComplianceOracle ora = new ComplianceOracle(address(mgr), _attestor());
        RiskPolicy pol = new RiskPolicy();
        manager = new HookPoolManagerStub();
        AmlHook unwired = _deployHook(mgr, reg, ora, pol);

        vm.prank(hookGovernor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, hookGovernor));
        unwired.setStalenessThreshold(120);
    }

    function test_ContractSubjectWithoutMultisigWhitelist_Reverts() external {
        MockTrustedRouter trusted = new MockTrustedRouter();
        MockTrustedRouter subject = new MockTrustedRouter();
        trusted.setMsgSender(address(subject));
        vm.prank(hookGovernor);
        hook.setTrustedRouter(address(trusted), true);

        vm.expectRevert(AmlHookLogic.MissingSwapSubject.selector);
        manager.callBeforeSwap(IHooks(address(hook)), address(trusted), key, params, "");
    }

    function test_TrustedGnosisSafe_AllCleanOwners_Resolves() external {
        address[] memory owners = new address[](2);
        owners[0] = walletA;
        owners[1] = walletB;
        MockGnosisSafe safe = new MockGnosisSafe(owners);

        vm.prank(hookGovernor);
        hook.setTrustedMultisig(address(safe), AmlHookLogic.MultisigType.GNOSIS_SAFE, true);

        vm.prank(keeper);
        complianceOracle.updateScore(address(safe), 0, 0, address(0), 0, _scoreSig(address(safe), 0, 0));

        address sender = _bindTrustedSubject(address(safe));
        (bytes4 sel,,) = manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
        assertEq(sel, hook.beforeSwap.selector);
    }

    function test_TrustedGnosisSafe_AllClean_RevertsIfOwnerSanctioned() external {
        address[] memory owners = new address[](2);
        owners[0] = walletA;
        owners[1] = walletB;
        MockGnosisSafe safe = new MockGnosisSafe(owners);

        vm.prank(hookGovernor);
        hook.setTrustedMultisig(address(safe), AmlHookLogic.MultisigType.GNOSIS_SAFE, true);

        _sanction(sanctionRegistry, keeper, walletB);

        address sender = _bindTrustedSubject(address(safe));
        vm.expectRevert(abi.encodeWithSelector(AmlHookLogic.SanctionHit.selector, walletB));
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
    }

    function test_TrustedGnosisSafe_AnyClean_AllowsIfOneOwnerClean() external {
        address[] memory owners = new address[](2);
        owners[0] = walletA;
        owners[1] = walletB;
        MockGnosisSafe safe = new MockGnosisSafe(owners);

        vm.prank(hookGovernor);
        hook.setTrustedMultisig(address(safe), AmlHookLogic.MultisigType.GNOSIS_SAFE, true);
        vm.prank(hookGovernor);
        hook.setMultisigAggregation(AmlHookLogic.MultisigAggregation.ANY_CLEAN);

        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, _scoreSig(walletA, 100, 0));
        vm.prank(keeper);
        complianceOracle.updateScore(address(safe), 0, 0, address(0), 0, _scoreSig(address(safe), 0, 0));

        address sender = _bindTrustedSubject(address(safe));
        (bytes4 sel,,) = manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
        assertEq(sel, hook.beforeSwap.selector);
    }

    function test_TrustedGnosisSafe_AllClean_RevertsIfOwnerInRevertBand() external {
        address[] memory owners = new address[](2);
        owners[0] = walletA;
        owners[1] = walletB;
        MockGnosisSafe safe = new MockGnosisSafe(owners);

        vm.prank(hookGovernor);
        hook.setTrustedMultisig(address(safe), AmlHookLogic.MultisigType.GNOSIS_SAFE, true);

        vm.prank(keeper);
        complianceOracle.updateScore(walletA, 100, 0, walletA, 0, _scoreSig(walletA, 100, 0));

        address sender = _bindTrustedSubject(address(safe));
        vm.expectRevert(
            abi.encodeWithSelector(AmlHookLogic.WalletBlocked.selector, walletA, 100, "MULTISIG_OWNER")
        );
        manager.callBeforeSwap(IHooks(address(hook)), sender, key, params, "");
    }
}
