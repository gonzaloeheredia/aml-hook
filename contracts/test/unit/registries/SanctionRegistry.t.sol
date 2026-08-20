// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {ISanctionRegistry} from "interfaces/registries/ISanctionRegistry.sol";
import {Roles} from "libraries/Roles.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

/// @notice Unit coverage for `SanctionRegistry` (incl. portable fuzz/isolation from aml-hook-dev).
contract UnitSanctionRegistryTest is Helpers {
    function setUp() public {
        accessManager = new AccessManager(owner);
        sanctionRegistry = new SanctionRegistry(address(accessManager));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = SanctionRegistry.setSanctioned.selector;
        selectors[1] = SanctionRegistry.commitSanction.selector;
        selectors[2] = SanctionRegistry.revealSanction.selector;
        _wireRole(accessManager, owner, address(sanctionRegistry), selectors, Roles._REGISTRY_KEEPER, keeper);
    }

    function test_ConstructorSetsAuthority(address initialAuthority) external {
        assertEq(new SanctionRegistry(initialAuthority).authority(), initialAuthority);
    }

    function test_IsSanctionedWhenAccountWasNeverListed(address account) external view {
        assertFalse(sanctionRegistry.isSanctioned(account));
    }

    /// @dev Emergency path: `setSanctioned` still applies a hit immediately.
    function test_SetSanctionedWhenListingAnAccount(address account) external {
        vm.expectEmit(true, false, false, true, address(sanctionRegistry));
        emit ISanctionRegistry.SanctionUpdated(account, true);

        vm.prank(keeper);
        sanctionRegistry.setSanctioned(account, true);
        assertTrue(sanctionRegistry.isSanctioned(account));
    }

    function test_SetSanctionedWhenDelistingAnAccount(address account) external {
        vm.prank(keeper);
        sanctionRegistry.setSanctioned(account, true);
        assertTrue(sanctionRegistry.isSanctioned(account));

        vm.prank(keeper);
        sanctionRegistry.setSanctioned(account, false);
        assertFalse(sanctionRegistry.isSanctioned(account));
    }

    function test_NonKeeperCannotSanction(address account) external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        sanctionRegistry.setSanctioned(account, true);
    }

    function test_ManagerAdminCannotSanction(address account) external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        sanctionRegistry.setSanctioned(account, true);
    }

    function test_RevokeRoleWhenKeeperIsCompromised(address account) external {
        vm.prank(keeper);
        sanctionRegistry.setSanctioned(account, true);

        vm.prank(owner);
        accessManager.revokeRole(Roles._REGISTRY_KEEPER, keeper);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        sanctionRegistry.setSanctioned(account, false);

        assertTrue(sanctionRegistry.isSanctioned(account));
    }

    function test_SetSanctionedWhenTargetIsUnwired(address account) external {
        SanctionRegistry unwired = new SanctionRegistry(address(accessManager));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        unwired.setSanctioned(account, true);
    }

    /*///////////////////////////////////////////////////////////////
                        COMMIT-REVEAL PATH (I-1)
    //////////////////////////////////////////////////////////////*/

    function test_CommitRevealSanctionsAccount(address account, bytes32 salt) external {
        vm.assume(account != address(0));
        bytes32 commitHash = keccak256(abi.encode(account, true, salt));

        vm.prank(keeper);
        sanctionRegistry.commitSanction(commitHash);
        assertEq(sanctionRegistry.commitBlocks(commitHash), block.number);

        vm.roll(block.number + sanctionRegistry.REVEAL_DELAY() + 1);

        vm.expectEmit(true, false, false, true, address(sanctionRegistry));
        emit ISanctionRegistry.SanctionUpdated(account, true);

        vm.prank(keeper);
        sanctionRegistry.revealSanction(account, true, salt);

        assertTrue(sanctionRegistry.isSanctioned(account));
        assertEq(sanctionRegistry.commitBlocks(commitHash), 0);
    }

    function test_CommitSanction_RevertsIfAlreadyUsed(bytes32 commitHash) external {
        vm.assume(commitHash != bytes32(0));
        vm.prank(keeper);
        sanctionRegistry.commitSanction(commitHash);

        vm.prank(keeper);
        vm.expectRevert(SanctionRegistry.CommitAlreadyUsed.selector);
        sanctionRegistry.commitSanction(commitHash);
    }

    function test_RevealSanction_RevertsTooEarly(address account, bytes32 salt) external {
        bytes32 commitHash = keccak256(abi.encode(account, true, salt));
        vm.prank(keeper);
        sanctionRegistry.commitSanction(commitHash);

        vm.prank(keeper);
        vm.expectRevert(SanctionRegistry.RevealTooEarly.selector);
        sanctionRegistry.revealSanction(account, true, salt);
    }

    function test_RevealSanction_RevertsOnUnknownCommit(address account, bytes32 salt) external {
        vm.prank(keeper);
        vm.expectRevert(SanctionRegistry.CommitNotFound.selector);
        sanctionRegistry.revealSanction(account, true, salt);
    }

    function test_RevealSanction_CannotBeReplayed(address account, bytes32 salt) external {
        _sanction(sanctionRegistry, keeper, account);
        vm.prank(keeper);
        vm.expectRevert(SanctionRegistry.CommitNotFound.selector);
        sanctionRegistry.revealSanction(account, true, salt);
    }

    function test_CommitSanction_RevertsForNonKeeper(bytes32 commitHash) external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        sanctionRegistry.commitSanction(commitHash);
    }
}
