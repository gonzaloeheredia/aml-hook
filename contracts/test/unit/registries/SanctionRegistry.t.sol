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

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SanctionRegistry.setSanctioned.selector;
        _wireRole(accessManager, owner, address(sanctionRegistry), selectors, Roles._REGISTRY_KEEPER, keeper);
    }

    function test_ConstructorSetsAuthority(address initialAuthority) external {
        assertEq(new SanctionRegistry(initialAuthority).authority(), initialAuthority);
    }

    function test_IsSanctionedWhenAccountWasNeverListed(address account) external view {
        assertFalse(sanctionRegistry.isSanctioned(account));
    }

    function test_SetSanctionedWhenCallerHasTheRole(address account, address other) external {
        vm.assume(account != other);

        vm.expectEmit(true, false, false, true, address(sanctionRegistry));
        emit ISanctionRegistry.SanctionUpdated(account, true);

        vm.prank(keeper);
        sanctionRegistry.setSanctioned(account, true);

        assertTrue(sanctionRegistry.isSanctioned(account));
        assertFalse(sanctionRegistry.isSanctioned(other));
    }

    function test_SetSanctionedWhenDelistingAnAccount(address account) external {
        vm.startPrank(keeper);
        sanctionRegistry.setSanctioned(account, true);
        sanctionRegistry.setSanctioned(account, false);
        vm.stopPrank();
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
}
