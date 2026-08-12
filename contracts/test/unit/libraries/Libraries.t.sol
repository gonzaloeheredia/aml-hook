// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";

/// @notice Unit coverage for `src/libraries/` (constants / enum ordinals must not drift).
contract UnitLibrariesTest is Test {
    function test_RolesIds_DoNotCollideWithAdminOrPublic() external pure {
        assertEq(Roles._REGISTRY_KEEPER, 1);
        assertEq(Roles._ORACLE_KEEPER, 2);
        assertEq(Roles._HOOK_GOVERNOR, 3);
        assertTrue(Roles._REGISTRY_KEEPER != 0);
        assertTrue(Roles._ORACLE_KEEPER != type(uint64).max);
    }

    function test_HookDecision_OrdinalsMatchTernarySpec() external pure {
        assertEq(uint8(HookDecision.ALLOW), 0);
        assertEq(uint8(HookDecision.FEE_OVERRIDE), 1);
        assertEq(uint8(HookDecision.REVERT), 2);
    }
}
