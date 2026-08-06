// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SanctionRegistry} from "../src/registries/SanctionRegistry.sol";

contract SanctionRegistryTest is Test {
    SanctionRegistry registry;
    address owner = address(this);
    address stranger = address(0xBAD);
    address wallet = address(0xA11CE);

    event SanctionUpdated(address indexed account, bool sanctioned);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        registry = new SanctionRegistry(owner);
    }

    function test_ConstructorSetsOwner() public view {
        assertEq(registry.owner(), owner);
    }

    function test_DefaultNotSanctioned() public view {
        assertFalse(registry.isSanctioned(wallet));
    }

    function test_OwnerCanSanctionAndClear() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit SanctionUpdated(wallet, true);
        registry.setSanctioned(wallet, true);
        assertTrue(registry.isSanctioned(wallet));

        vm.expectEmit(true, false, false, true, address(registry));
        emit SanctionUpdated(wallet, false);
        registry.setSanctioned(wallet, false);
        assertFalse(registry.isSanctioned(wallet));
    }

    function test_NonOwnerCannotSanction() public {
        vm.prank(stranger);
        vm.expectRevert(SanctionRegistry.NotOwner.selector);
        registry.setSanctioned(wallet, true);
    }

    function test_TransferOwnership() public {
        address next = address(0xB0B);
        vm.expectEmit(true, true, false, true, address(registry));
        emit OwnershipTransferred(owner, next);
        registry.transferOwnership(next);
        assertEq(registry.owner(), next);

        vm.expectRevert(SanctionRegistry.NotOwner.selector);
        registry.setSanctioned(wallet, true);

        vm.prank(next);
        registry.setSanctioned(wallet, true);
        assertTrue(registry.isSanctioned(wallet));
    }
}
