// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ISanctionRegistry} from "interfaces/registries/ISanctionRegistry.sol";
import {
    MultisigAggregation,
    MultisigType,
    TrustedMultisig,
    WalletSubject
} from "libraries/WalletSubject.sol";
import {MockGnosisSafe} from "test/mocks/MockGnosisSafe.sol";

/// @dev IMsgSender stand-in; lives here so coverage never pulls `script/`.
contract WalletSubjectRouter {
    address private _subject;
    bool private _revertOnRead;

    function setMsgSender(address subject) external {
        _subject = subject;
    }

    function setRevertOnRead(bool revertOnRead) external {
        _revertOnRead = revertOnRead;
    }

    function msgSender() external view returns (address) {
        if (_revertOnRead) revert("msgSender");
        return _subject;
    }
}

contract WalletSubjectSanctionList is ISanctionRegistry {
    mapping(address => bool) private _sanctioned;

    function isSanctioned(address account) external view returns (bool) {
        return _sanctioned[account];
    }

    function setSanctioned(address account, bool sanctioned) external {
        _sanctioned[account] = sanctioned;
    }
}

contract RevertingOwners {
    function getOwners() external pure returns (address[] memory) {
        revert("owners");
    }
}

/// @dev Concrete wrapper so unit tests hit the library without Uniswap v4.
contract WalletSubjectHarness {
    mapping(address => bool) public trustedRouters;
    mapping(address => TrustedMultisig) public trustedMultisigs;

    function setTrustedRouter(address router, bool trusted) external {
        trustedRouters[router] = trusted;
    }

    function setTrustedMultisig(address account, MultisigType kind, bool trusted) external {
        trustedMultisigs[account] = TrustedMultisig({trusted: trusted, kind: kind});
    }

    function resolve(address router, ISanctionRegistry registry, MultisigAggregation aggregation)
        external
        view
        returns (address)
    {
        return WalletSubject.resolve(router, trustedRouters, trustedMultisigs, registry, aggregation);
    }

    function requireOwnersClean(
        address wallet,
        MultisigType kind,
        ISanctionRegistry registry,
        MultisigAggregation aggregation
    ) external view {
        WalletSubject.requireOwnersClean(wallet, kind, registry, aggregation);
    }

    function resolveLp(address sender, ISanctionRegistry registry, MultisigAggregation aggregation)
        external
        view
        returns (address wallet, bool viaTrustedRouter)
    {
        return WalletSubject.resolveLp(sender, trustedRouters, trustedMultisigs, registry, aggregation);
    }

    function layer1Hit(address wallet, ISanctionRegistry registry, MultisigAggregation aggregation)
        external
        view
        returns (address)
    {
        return WalletSubject.layer1Hit(wallet, trustedMultisigs, registry, aggregation);
    }
}

/// @notice Direct unit coverage for `WalletSubject` (router / Safe / subject). No v4-core.
contract UnitWalletSubjectTest is Test {
    WalletSubjectHarness internal subject;
    WalletSubjectRouter internal router;
    WalletSubjectSanctionList internal registry;

    address internal eoa = makeAddr("eoa");
    address internal ownerA = makeAddr("ownerA");
    address internal ownerB = makeAddr("ownerB");

    function setUp() public {
        subject = new WalletSubjectHarness();
        router = new WalletSubjectRouter();
        registry = new WalletSubjectSanctionList();
        subject.setTrustedRouter(address(router), true);
    }

    function test_Resolve_UntrustedRouter_RevertsMissingSwapSubject() external {
        vm.expectRevert(WalletSubject.MissingSwapSubject.selector);
        subject.resolve(makeAddr("other"), registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_Resolve_TrustedRouterMsgSenderReverts() external {
        router.setRevertOnRead(true);
        vm.expectRevert(
            abi.encodeWithSelector(WalletSubject.TrustedRouterSubjectFailed.selector, address(router))
        );
        subject.resolve(address(router), registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_Resolve_ZeroMsgSender_Reverts() external {
        router.setMsgSender(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(WalletSubject.TrustedRouterSubjectFailed.selector, address(router))
        );
        subject.resolve(address(router), registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_Resolve_EoaSubject_ReturnsWalletWithoutOwnerScreen() external {
        router.setMsgSender(eoa);
        address wallet = subject.resolve(address(router), registry, MultisigAggregation.ALL_CLEAN);
        assertEq(wallet, eoa);
    }

    function test_Resolve_ContractSubjectNotWhitelisted_Reverts() external {
        WalletSubjectRouter nested = new WalletSubjectRouter();
        router.setMsgSender(address(nested));
        vm.expectRevert(WalletSubject.MissingSwapSubject.selector);
        subject.resolve(address(router), registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_Resolve_RevokedMultisig_Reverts() external {
        address[] memory owners = new address[](1);
        owners[0] = ownerA;
        MockGnosisSafe safe = new MockGnosisSafe(owners);
        subject.setTrustedMultisig(address(safe), MultisigType.GNOSIS_SAFE, false);
        router.setMsgSender(address(safe));
        vm.expectRevert(WalletSubject.MissingSwapSubject.selector);
        subject.resolve(address(router), registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_Resolve_TrustedSafe_AllCleanOwners_ReturnsSafe() external {
        MockGnosisSafe safe = _safe(ownerA, ownerB);
        subject.setTrustedMultisig(address(safe), MultisigType.GNOSIS_SAFE, true);
        router.setMsgSender(address(safe));
        assertEq(subject.resolve(address(router), registry, MultisigAggregation.ALL_CLEAN), address(safe));
    }

    function test_Resolve_TrustedSafe_AllClean_OwnerSanctioned_Reverts() external {
        MockGnosisSafe safe = _safe(ownerA, ownerB);
        subject.setTrustedMultisig(address(safe), MultisigType.GNOSIS_SAFE, true);
        registry.setSanctioned(ownerB, true);
        router.setMsgSender(address(safe));
        vm.expectRevert(abi.encodeWithSelector(WalletSubject.SanctionHit.selector, ownerB));
        subject.resolve(address(router), registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_Resolve_TrustedSafe_AnyClean_OneOwnerClean_ReturnsSafe() external {
        MockGnosisSafe safe = _safe(ownerA, ownerB);
        subject.setTrustedMultisig(address(safe), MultisigType.GNOSIS_SAFE, true);
        registry.setSanctioned(ownerB, true);
        router.setMsgSender(address(safe));
        assertEq(subject.resolve(address(router), registry, MultisigAggregation.ANY_CLEAN), address(safe));
    }

    function test_Resolve_TrustedSafe_AnyClean_AllOwnersSanctioned_RevertsFirst() external {
        MockGnosisSafe safe = _safe(ownerA, ownerB);
        subject.setTrustedMultisig(address(safe), MultisigType.GNOSIS_SAFE, true);
        registry.setSanctioned(ownerA, true);
        registry.setSanctioned(ownerB, true);
        router.setMsgSender(address(safe));
        vm.expectRevert(abi.encodeWithSelector(WalletSubject.SanctionHit.selector, ownerA));
        subject.resolve(address(router), registry, MultisigAggregation.ANY_CLEAN);
    }

    function test_RequireOwnersClean_UnsupportedKind_Reverts() external {
        MockGnosisSafe safe = _safe(ownerA, ownerB);
        vm.expectRevert(WalletSubject.MissingSwapSubject.selector);
        subject.requireOwnersClean(address(safe), MultisigType.NONE, registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_RequireOwnersClean_GetOwnersReverts() external {
        RevertingOwners bad = new RevertingOwners();
        vm.expectRevert(WalletSubject.MissingSwapSubject.selector);
        subject.requireOwnersClean(address(bad), MultisigType.GNOSIS_SAFE, registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_RequireOwnersClean_EmptyOwnerList_Reverts() external {
        address[] memory owners;
        MockGnosisSafe safe = new MockGnosisSafe(owners);
        vm.expectRevert(WalletSubject.MissingSwapSubject.selector);
        subject.requireOwnersClean(address(safe), MultisigType.GNOSIS_SAFE, registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_RequireOwnersClean_EoaHasNoGetOwners_Reverts() external {
        // EOA call succeeds with empty returndata; ABI decode of `address[]` reverts without data.
        vm.expectRevert();
        subject.requireOwnersClean(eoa, MultisigType.GNOSIS_SAFE, registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_RequireOwnersClean_AllClean_FirstOwnerSanctioned_RevertsFirst() external {
        MockGnosisSafe safe = _safe(ownerA, ownerB);
        registry.setSanctioned(ownerA, true);
        vm.expectRevert(abi.encodeWithSelector(WalletSubject.SanctionHit.selector, ownerA));
        subject.requireOwnersClean(address(safe), MultisigType.GNOSIS_SAFE, registry, MultisigAggregation.ALL_CLEAN);
    }

    function test_RequireOwnersClean_AnyClean_MixedOwners_Passes() external {
        MockGnosisSafe safe = _safe(ownerA, ownerB);
        registry.setSanctioned(ownerA, true);
        subject.requireOwnersClean(address(safe), MultisigType.GNOSIS_SAFE, registry, MultisigAggregation.ANY_CLEAN);
    }

    function test_ResolveLp_DirectSender_IsSubject() external view {
        (address wallet, bool viaRouter) = subject.resolveLp(eoa, registry, MultisigAggregation.ALL_CLEAN);
        assertEq(wallet, eoa);
        assertFalse(viaRouter);
    }

    function test_ResolveLp_TrustedRouter_UsesMsgSender() external {
        router.setMsgSender(eoa);
        (address wallet, bool viaRouter) =
            subject.resolveLp(address(router), registry, MultisigAggregation.ALL_CLEAN);
        assertEq(wallet, eoa);
        assertTrue(viaRouter);
    }

    function test_Layer1Hit_ListedSubject() external {
        registry.setSanctioned(eoa, true);
        assertEq(subject.layer1Hit(eoa, registry, MultisigAggregation.ALL_CLEAN), eoa);
    }

    function test_Layer1Hit_ListedSafeOwner() external {
        MockGnosisSafe safe = _safe(ownerA, ownerB);
        subject.setTrustedMultisig(address(safe), MultisigType.GNOSIS_SAFE, true);
        registry.setSanctioned(ownerB, true);
        assertEq(subject.layer1Hit(address(safe), registry, MultisigAggregation.ALL_CLEAN), ownerB);
    }

    function _safe(address a, address b) internal returns (MockGnosisSafe) {
        address[] memory owners = new address[](2);
        owners[0] = a;
        owners[1] = b;
        return new MockGnosisSafe(owners);
    }
}
