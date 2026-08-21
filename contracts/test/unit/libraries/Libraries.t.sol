// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeeBps} from "libraries/FeeBps.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {UniversalRouters} from "libraries/UniversalRouters.sol";

/// @notice Unit coverage for `src/libraries/` (constants / enum ordinals must not drift).
contract UnitLibrariesTest is Test {
    function test_RolesIds_DoNotCollideWithAdminOrPublic() external pure {
        assertEq(Roles._REGISTRY_KEEPER, 1);
        assertEq(Roles._ORACLE_KEEPER, 2);
        assertEq(Roles._HOOK_GOVERNOR, 3);
        assertTrue(Roles._REGISTRY_KEEPER != 0);
        assertTrue(Roles._ORACLE_KEEPER != type(uint64).max);
    }

    function test_FeeBps_SharedLatencyResolution() external pure {
        assertEq(FeeBps.STANDARD, 30);
        assertEq(FeeBps.LATENCY, 800);
        assertEq(FeeBps.MAX_OVERRIDE, 1000);
        assertEq(FeeBps.MIN_INFLOW_THRESHOLD, 100);
        assertEq(FeeBps.resolveLatencyFee(0), 800);
        assertEq(FeeBps.resolveLatencyFee(500), 500);
        assertEq(FeeBps.resolveLatencyFee(1001), 800);
        assertEq(FeeBps.differentialBps(0), 0);
        assertEq(FeeBps.differentialBps(30), 0);
        assertEq(FeeBps.differentialBps(800), 770);
        assertEq(FeeBps.differentialAmount(1e18, 30), 0);
        assertEq(FeeBps.differentialAmount(1e18, 800), (uint256(1e18) * 770) / 10_000);
    }

    function test_HookDecision_OrdinalsMatchTernarySpec() external pure {
        assertEq(uint8(HookDecision.ALLOW), 0);
        assertEq(uint8(HookDecision.FEE_OVERRIDE), 1);
        assertEq(uint8(HookDecision.REVERT), 2);
    }

    function test_UniversalRouters_AppUniswapOrgAddresses() external pure {
        assertEq(UniversalRouters.appRouter(1), 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
        assertEq(UniversalRouters.appRouter(130), 0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3);
        assertEq(UniversalRouters.appRouter(8453), 0x6fF5693b99212Da76ad316178A184AB56D299b43);
        assertEq(UniversalRouters.appRouter(31337), address(0));
        assertTrue(UniversalRouters.appRouterV211(1) != UniversalRouters.appRouter(1));
        assertTrue(UniversalRouters.appRouterV211(1) != address(0));
    }
}
