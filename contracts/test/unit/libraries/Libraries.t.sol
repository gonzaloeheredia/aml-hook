// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeeBps} from "libraries/FeeBps.sol";
import {HookDecision} from "libraries/HookDecision.sol";
import {Roles} from "libraries/Roles.sol";
import {ChainlinkFeeds} from "libraries/ChainlinkFeeds.sol";
import {UniversalRouters} from "libraries/UniversalRouters.sol";
import {PoolImpact} from "libraries/PoolImpact.sol";
import {UsdQuote} from "libraries/UsdQuote.sol";

/// @notice Unit coverage for `src/libraries/` (constants / enum ordinals must not drift).
contract UnitLibrariesTest is Test {
    function test_RolesIds_DoNotCollideWithAdminOrPublic() external pure {
        assertEq(Roles._REGISTRY_KEEPER, 1);
        assertEq(Roles._ORACLE_KEEPER, 2);
        assertEq(Roles._HOOK_GOVERNOR, 3);
        assertEq(Roles._COMPLIANCE_OFFICER, 4);
        assertTrue(Roles._REGISTRY_KEEPER != 0);
        assertTrue(Roles._ORACLE_KEEPER != type(uint64).max);
        assertTrue(Roles._COMPLIANCE_OFFICER != type(uint64).max);
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

    function test_UsdQuote_EighteenDecimalsMatchesOneToOneUsd() external pure {
        // 1e18 tokens at $1 (1e8, 8 feed decimals) → $1 in USD-8.
        assertEq(UsdQuote.toUsd8(1e18, 18, 1e8, 8), 1e8);
        assertEq(UsdQuote.toUsd8(1_000e18, 18, 1e8, 8), 1_000e8);
    }

    function test_UsdQuote_SixDecimalsMatchesOneToOneUsd() external pure {
        // 1e6 tokens (USDC-like) at $1 → $1 in USD-8. Same USD as 1e18 of an 18-dec token.
        assertEq(UsdQuote.toUsd8(1e6, 6, 1e8, 8), 1e8);
        assertEq(UsdQuote.toUsd8(1_000e6, 6, 1e8, 8), 1_000e8);
        assertEq(UsdQuote.toUsd8(1e6, 6, 1e8, 8), UsdQuote.toUsd8(1e18, 18, 1e8, 8));
    }

    function test_UsdQuote_ZeroAmountOrPriceIsZero() external pure {
        assertEq(UsdQuote.toUsd8(0, 18, 1e8, 8), 0);
        assertEq(UsdQuote.toUsd8(1e18, 18, 0, 8), 0);
    }

    function test_ChainlinkFeeds_OfficialEthUsdProxies() external pure {
        assertEq(ChainlinkFeeds.ethUsd(1), 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        assertEq(ChainlinkFeeds.ethUsd(8453), 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
        assertEq(ChainlinkFeeds.ethUsd(11155111), 0x694AA1769357215DE4FAC081bf1f309aDC325306);
        assertEq(ChainlinkFeeds.ethUsd(31337), address(0));
        assertEq(ChainlinkFeeds.usdcUsd(1), 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        assertEq(ChainlinkFeeds.weth(1), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertEq(ChainlinkFeeds.usdc(1), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    }

    function test_UniversalRouters_AppUniswapOrgAddresses() external pure {
        assertEq(UniversalRouters.appRouter(1), 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
        assertEq(UniversalRouters.appRouter(130), 0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3);
        assertEq(UniversalRouters.appRouter(8453), 0x6fF5693b99212Da76ad316178A184AB56D299b43);
        assertEq(UniversalRouters.appRouter(31337), address(0));
        assertTrue(UniversalRouters.appRouterV211(1) != UniversalRouters.appRouter(1));
        assertTrue(UniversalRouters.appRouterV211(1) != address(0));
    }

    function test_PoolImpact_EmptyReserveIsFullDrain() external pure {
        assertEq(PoolImpact.impactBps(1, 0), 10_000);
        assertEq(PoolImpact.impactBps(50, 100), 5_000);
        assertEq(PoolImpact.virtualReserve(0, 1, true), 0);
    }
}
