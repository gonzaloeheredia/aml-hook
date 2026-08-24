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
        assertEq(PoolImpact.virtualReserve(1, 0, false), 0);
    }

    function test_PoolImpact_OneToOnePriceVirtualReserve() external pure {
        uint160 sqrtPriceX96 = uint160(PoolImpact.Q96);
        uint128 liquidity = 1e18;
        assertEq(PoolImpact.virtualReserve(liquidity, sqrtPriceX96, true), uint256(liquidity));
        assertEq(PoolImpact.virtualReserve(liquidity, sqrtPriceX96, false), uint256(liquidity));
    }

    function test_UniversalRouters_KnownChainsAndUnknownAreZero() external pure {
        uint256[12] memory chains = [
            uint256(1),
            uint256(10),
            uint256(56),
            uint256(130),
            uint256(137),
            uint256(8453),
            uint256(42161),
            uint256(43114),
            uint256(11155111),
            uint256(1301),
            uint256(84532),
            uint256(31337)
        ];
        for (uint256 i; i < chains.length; ++i) {
            address router = UniversalRouters.appRouter(chains[i]);
            if (chains[i] == 31337) assertEq(router, address(0));
            else assertTrue(router != address(0));
        }
        assertEq(UniversalRouters.appRouterV211(84532), address(0));
        assertEq(UniversalRouters.appRouter(999999), address(0));
        assertEq(UniversalRouters.appRouterV211(999999), address(0));
    }

    function test_ChainlinkFeeds_KnownChainsAndUnknownAreZero() external pure {
        assertEq(ChainlinkFeeds.ethUsd(10), 0x13e3Ee699D1909E989722E753853AE30b17e08c5);
        assertEq(ChainlinkFeeds.usdcUsd(8453), 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B);
        assertEq(ChainlinkFeeds.weth(8453), 0x4200000000000000000000000000000000000006);
        assertEq(ChainlinkFeeds.usdc(84532), 0x036CbD53842c5426634e7929541eC2318f3dCF7e);
        assertEq(ChainlinkFeeds.ethUsd(999999), address(0));
        assertEq(ChainlinkFeeds.usdcUsd(130), address(0));
        assertEq(ChainlinkFeeds.usdcUsd(999999), address(0));
        assertEq(ChainlinkFeeds.weth(999999), address(0));
        assertEq(ChainlinkFeeds.usdc(999999), address(0));
    }

    function testFuzz_FeeBps_DifferentialNeverExceedsInput(uint24 feeBps, uint256 basisAmount) external pure {
        // Production fees sit at or below MAX_OVERRIDE (10%). Above 100% the slice can exceed basis.
        feeBps = uint24(bound(feeBps, 0, FeeBps.STANDARD + 10_000));
        basisAmount = bound(basisAmount, 0, type(uint128).max);
        uint256 slice = FeeBps.differentialAmount(basisAmount, feeBps);
        uint256 bps = FeeBps.differentialBps(feeBps);
        if (feeBps <= FeeBps.STANDARD || basisAmount == 0) {
            assertEq(slice, 0);
            assertEq(bps, 0);
        } else {
            assertEq(bps, uint256(feeBps) - uint256(FeeBps.STANDARD));
            assertEq(slice, (basisAmount * bps) / 10_000);
            assertLe(slice, basisAmount);
        }
    }

    function testFuzz_FeeBps_ResolveLatencyFee(uint24 recommended) external pure {
        uint24 resolved = FeeBps.resolveLatencyFee(recommended);
        if (recommended > 0 && recommended <= FeeBps.MAX_OVERRIDE) assertEq(resolved, recommended);
        else assertEq(resolved, FeeBps.LATENCY);
    }

    function testFuzz_UsdQuote_SixAndEighteenDecimalsAgreeAtOneDollar(uint256 wholeTokens) external pure {
        wholeTokens = bound(wholeTokens, 0, 1e12);
        uint256 usd18 = UsdQuote.toUsd8(wholeTokens * 1e18, 18, 1e8, 8);
        uint256 usd6 = UsdQuote.toUsd8(wholeTokens * 1e6, 6, 1e8, 8);
        assertEq(usd18, usd6);
        assertEq(usd18, wholeTokens * 1e8);
    }

    function testFuzz_UsdQuote_ZeroInputsStayZero(uint8 tokenDecimals, uint8 feedDecimals, uint256 price)
        external
        pure
    {
        tokenDecimals = uint8(bound(tokenDecimals, 0, 18));
        feedDecimals = uint8(bound(feedDecimals, 0, 18));
        price = bound(price, 1, 1e18);
        assertEq(UsdQuote.toUsd8(0, tokenDecimals, price, feedDecimals), 0);
        assertEq(UsdQuote.toUsd8(1e18, tokenDecimals, 0, feedDecimals), 0);
    }

    function testFuzz_PoolImpact_ImpactBpsCappedAtMax(uint256 amount, uint256 reserve) external pure {
        amount = bound(amount, 0, type(uint256).max / PoolImpact.MAX_BPS);
        uint256 bps = PoolImpact.impactBps(amount, reserve);
        assertLe(bps, PoolImpact.MAX_BPS);
        if (reserve == 0 || amount >= reserve) assertEq(bps, PoolImpact.MAX_BPS);
        else assertEq(bps, (amount * PoolImpact.MAX_BPS) / reserve);
    }

    function testFuzz_PoolImpact_VirtualReserveZeroInputs(uint128 liquidity, uint160 sqrtPriceX96, bool token0)
        external
        pure
    {
        if (liquidity == 0 || sqrtPriceX96 == 0) {
            assertEq(PoolImpact.virtualReserve(liquidity, sqrtPriceX96, token0), 0);
        }
    }

    function testFuzz_UniversalRouters_UnknownChainIdIsZero(uint256 chainId) external pure {
        if (
            chainId == 1 || chainId == 10 || chainId == 56 || chainId == 130 || chainId == 137 || chainId == 8453
                || chainId == 42161 || chainId == 43114 || chainId == 11155111 || chainId == 1301 || chainId == 84532
        ) {
            assertTrue(UniversalRouters.appRouter(chainId) != address(0));
            return;
        }
        assertEq(UniversalRouters.appRouter(chainId), address(0));
    }

    function testFuzz_ChainlinkFeeds_UnknownChainIdIsZero(uint256 chainId) external pure {
        if (
            chainId == 1 || chainId == 10 || chainId == 56 || chainId == 130 || chainId == 137 || chainId == 8453
                || chainId == 42161 || chainId == 43114 || chainId == 11155111 || chainId == 84532
        ) {
            assertTrue(ChainlinkFeeds.ethUsd(chainId) != address(0));
            return;
        }
        assertEq(ChainlinkFeeds.ethUsd(chainId), address(0));
    }
}
