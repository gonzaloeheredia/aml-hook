// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {SanctionRegistry} from "contracts/registries/SanctionRegistry.sol";
import {ISanctionRegistry} from "interfaces/registries/ISanctionRegistry.sol";
import {Roles} from "libraries/Roles.sol";
import {Helpers} from "test/utils/Helpers.t.sol";

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

    function test_DefaultNotSanctioned() external view {
        assertFalse(sanctionRegistry.isSanctioned(walletA));
    }

    function test_KeeperCanSanctionAndClear() external {
        vm.expectEmit(true, false, false, true, address(sanctionRegistry));
        emit ISanctionRegistry.SanctionUpdated(walletA, true);
        vm.prank(keeper);
        sanctionRegistry.setSanctioned(walletA, true);
        assertTrue(sanctionRegistry.isSanctioned(walletA));

        vm.expectEmit(true, false, false, true, address(sanctionRegistry));
        emit ISanctionRegistry.SanctionUpdated(walletA, false);
        vm.prank(keeper);
        sanctionRegistry.setSanctioned(walletA, false);
        assertFalse(sanctionRegistry.isSanctioned(walletA));
    }

    function test_NonKeeperCannotSanction() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        sanctionRegistry.setSanctioned(walletA, true);
    }

    /// @dev The manager admin governs roles and is not granted this one, so it cannot write the list.
    function test_ManagerAdminCannotSanction() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        sanctionRegistry.setSanctioned(walletA, true);
    }

    /// @dev Revoking on the shared manager stops future writes; what was written stands until overwritten.
    function test_RevokeRoleWhenKeeperIsCompromised() external {
        vm.prank(keeper);
        sanctionRegistry.setSanctioned(walletA, true);

        vm.prank(owner);
        accessManager.revokeRole(Roles._REGISTRY_KEEPER, keeper);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        sanctionRegistry.setSanctioned(walletA, false);

        assertTrue(sanctionRegistry.isSanctioned(walletA));
    }

    /// @dev A function nobody wired stays admin-only, so a forgotten deploy step fails closed.
    function test_SetSanctionedWhenTargetIsUnwired() external {
        SanctionRegistry unwired = new SanctionRegistry(address(accessManager));

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        unwired.setSanctioned(walletA, true);
    }
}
