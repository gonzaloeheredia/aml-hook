// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IAggregatorV3} from "interfaces/external/IAggregatorV3.sol";
import {OracleQuote} from "libraries/OracleQuote.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract RevertingDecimalsFeed is IAggregatorV3 {
    function decimals() external pure returns (uint8) {
        revert("decimals");
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

contract NoDecimalsToken {}

contract RevertingDecimalsToken {
    function decimals() external pure returns (uint8) {
        revert("decimals");
    }
}

/// @dev Concrete wrapper so unit tests hit OracleQuote without Uniswap v4.
contract OracleQuoteHarness {
    mapping(address => IAggregatorV3) public priceFeeds;
    mapping(address => OracleQuote.CachedFx) public lastFx;

    function setFeed(address token, address feed) external {
        priceFeeds[token] = IAggregatorV3(feed);
    }

    function seedCache(address token, uint256 price, uint64 quotedAt, uint8 feedDecimals, uint8 tokenDecimals)
        external
    {
        lastFx[token] = OracleQuote.CachedFx({
            price: price,
            quotedAt: quotedAt,
            feedDecimals: feedDecimals,
            tokenDecimals: tokenDecimals
        });
    }

    function resolve(uint256 priceStalenessThreshold, uint256 maxPriceStaleness, address token)
        external
        view
        returns (OracleQuote.Fx memory fx, bytes32 err)
    {
        return OracleQuote.resolve(priceFeeds, lastFx, priceStalenessThreshold, maxPriceStaleness, token);
    }

    function commit(address token, OracleQuote.Fx memory fx) external {
        OracleQuote.commit(lastFx, token, fx);
    }

    function toUsd(OracleQuote.Fx memory fx, uint256 amount) external pure returns (uint256) {
        return OracleQuote.toUsd(fx, amount);
    }

    function pack(OracleQuote.Fx memory fx) external pure returns (uint256) {
        return OracleQuote.pack(fx);
    }

    function unpack(uint256 price, uint256 packed) external pure returns (OracleQuote.Fx memory) {
        return OracleQuote.unpack(price, packed);
    }

    function tokenDecimalsOf(address token) external view returns (uint8, bool) {
        return OracleQuote.tokenDecimalsOf(token);
    }

    function noFeed() external pure returns (bytes32) {
        return OracleQuote.NO_FEED;
    }

    function staleFeed() external pure returns (bytes32) {
        return OracleQuote.STALE_FEED;
    }

    function badPrice() external pure returns (bytes32) {
        return OracleQuote.BAD_PRICE;
    }

    function windowFailed() external pure returns (bytes32) {
        return OracleQuote.WINDOW_FAILED;
    }

    function hotTtl() external pure returns (uint256) {
        return OracleQuote.HOT_TTL;
    }
}

/// @notice Direct unit coverage for `OracleQuote` (feeds, stale, decimals, lastFx). No v4-core.
contract UnitOracleQuoteTest is Test {
    OracleQuoteHarness internal quote;
    MockAggregatorV3 internal feed;
    MockERC20 internal token;

    uint256 internal constant STALE_LIVE = 1 hours;
    uint256 internal constant MAX_STALE = 24 hours;

    function setUp() public {
        quote = new OracleQuoteHarness();
        feed = new MockAggregatorV3();
        token = new MockERC20();
        feed.setRound(1e8, block.timestamp);
        quote.setFeed(address(token), address(feed));
    }

    function test_Constants_MatchSpec() external view {
        assertEq(quote.noFeed(), keccak256("NO_FEED"));
        assertEq(quote.staleFeed(), keccak256("STALE_FEED"));
        assertEq(quote.badPrice(), keccak256("BAD_PRICE"));
        assertEq(quote.windowFailed(), keccak256("WINDOW_FAILED"));
        assertEq(quote.hotTtl(), 30 minutes);
    }

    function test_Resolve_LiveRound_Succeeds() external view {
        (OracleQuote.Fx memory fx, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, bytes32(0));
        assertEq(fx.price, 1e8);
        assertEq(fx.quotedAt, uint64(block.timestamp));
        assertEq(fx.feedDecimals, 8);
        assertEq(fx.tokenDecimals, 18);
        assertFalse(fx.fromCache);
        assertFalse(fx.stale);
    }

    function test_Resolve_HotCache_SkipsChainlink() external {
        quote.seedCache(address(token), 42e8, uint64(block.timestamp), 8, 18);
        feed.setRound(99e8, block.timestamp);
        (OracleQuote.Fx memory fx, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, bytes32(0));
        assertEq(fx.price, 42e8);
        assertTrue(fx.fromCache);
        assertFalse(fx.stale);
    }

    function test_Resolve_HotCache_EmptyPriceIsNotHot() external {
        quote.seedCache(address(token), 0, uint64(block.timestamp), 8, 18);
        (OracleQuote.Fx memory fx, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, bytes32(0));
        assertEq(fx.price, 1e8);
        assertFalse(fx.fromCache);
    }

    function test_Resolve_NoFeed_EmptyCache_ReturnsNoFeed() external {
        MockERC20 orphan = new MockERC20();
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(orphan));
        assertEq(err, quote.noFeed());
    }

    function test_Resolve_NoFeed_UsesLastFxUntilMaxStaleness() external {
        quote.seedCache(address(token), 1e8, uint64(block.timestamp), 8, 6);
        quote.setFeed(address(token), address(0));
        vm.warp(block.timestamp + 31 minutes);
        (OracleQuote.Fx memory fx, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, bytes32(0));
        assertEq(fx.price, 1e8);
        assertEq(fx.tokenDecimals, 6);
        assertTrue(fx.fromCache);
        assertTrue(fx.stale);
    }

    function test_Resolve_NoFeed_CacheExpired_ReturnsStaleFeed() external {
        quote.seedCache(address(token), 1e8, uint64(block.timestamp), 8, 18);
        quote.setFeed(address(token), address(0));
        vm.warp(block.timestamp + MAX_STALE + 1);
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, quote.staleFeed());
    }

    function test_Resolve_LiveRoundReverts_FallsBackToCache() external {
        vm.warp(2 hours);
        quote.seedCache(address(token), 7e8, uint64(block.timestamp - 31 minutes), 8, 18);
        feed.setRevertOnRead(true);
        (OracleQuote.Fx memory fx, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, bytes32(0));
        assertEq(fx.price, 7e8);
        assertTrue(fx.fromCache);
        assertTrue(fx.stale);
    }

    function test_Resolve_LiveRoundReverts_EmptyCache_ReturnsBadPrice() external {
        feed.setRevertOnRead(true);
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, quote.badPrice());
    }

    function test_Resolve_NonPositivePrice_ReturnsBadPrice() external {
        feed.setRound(0, block.timestamp);
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, quote.badPrice());
        feed.setRound(-1, block.timestamp);
        (, err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, quote.badPrice());
    }

    function test_Resolve_ZeroUpdatedAt_ReturnsBadPrice() external {
        feed.setRound(1e8, 0);
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, quote.badPrice());
    }

    function test_Resolve_AnsweredInRoundBehind_ReturnsBadPrice() external {
        feed.setAnsweredInRound(0);
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, quote.badPrice());
    }

    function test_Resolve_FeedDecimalsRevert_ReturnsBadPrice() external {
        quote.setFeed(address(token), address(new RevertingDecimalsFeed()));
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, quote.badPrice());
    }

    function test_Resolve_FeedDecimalsAbove18_ReturnsBadPrice() external {
        feed.setDecimals(19);
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, quote.badPrice());
    }

    function test_Resolve_TokenDecimalsAbove36_ReturnsBadPrice() external {
        token.setDecimals(37);
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, quote.badPrice());
    }

    function test_Resolve_TokenDecimalsRevert_ReturnsBadPrice() external {
        RevertingDecimalsToken bad = new RevertingDecimalsToken();
        quote.setFeed(address(bad), address(feed));
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(bad));
        assertEq(err, quote.badPrice());
    }

    function test_Resolve_LiveOlderThanThreshold_MarksStaleButSucceeds() external {
        vm.warp(2 hours);
        feed.setRound(1e8, block.timestamp - STALE_LIVE - 1);
        (OracleQuote.Fx memory fx, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, bytes32(0));
        assertTrue(fx.stale);
        assertFalse(fx.fromCache);
    }

    function test_Resolve_AfterHotTtl_ReadsLive() external {
        quote.seedCache(address(token), 1e8, uint64(block.timestamp), 8, 18);
        vm.warp(block.timestamp + 30 minutes + 1);
        feed.setRound(55e8, block.timestamp);
        (OracleQuote.Fx memory fx, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, bytes32(0));
        assertEq(fx.price, 55e8);
        assertFalse(fx.fromCache);
    }

    function test_Commit_LiveRound_WritesCache() external {
        OracleQuote.Fx memory fx = OracleQuote.Fx({
            price: 2e8,
            quotedAt: 1_700_000_000,
            feedDecimals: 8,
            tokenDecimals: 6,
            fromCache: false,
            stale: false
        });
        quote.commit(address(token), fx);
        (uint256 price, uint64 quotedAt, uint8 feedDecimals, uint8 tokenDecimals) = quote.lastFx(address(token));
        assertEq(price, 2e8);
        assertEq(quotedAt, 1_700_000_000);
        assertEq(feedDecimals, 8);
        assertEq(tokenDecimals, 6);
    }

    function test_Commit_FromCache_IsNoop() external {
        quote.seedCache(address(token), 1e8, 100, 8, 18);
        OracleQuote.Fx memory fx = OracleQuote.Fx({
            price: 9e8,
            quotedAt: 200,
            feedDecimals: 8,
            tokenDecimals: 18,
            fromCache: true,
            stale: true
        });
        quote.commit(address(token), fx);
        (uint256 price, uint64 quotedAt,,) = quote.lastFx(address(token));
        assertEq(price, 1e8);
        assertEq(quotedAt, 100);
    }

    function test_Commit_ZeroPrice_IsNoop() external {
        quote.seedCache(address(token), 1e8, 100, 8, 18);
        OracleQuote.Fx memory fx;
        fx.quotedAt = 200;
        quote.commit(address(token), fx);
        (uint256 price, uint64 quotedAt,,) = quote.lastFx(address(token));
        assertEq(price, 1e8);
        assertEq(quotedAt, 100);
    }

    function test_ToUsd_ZeroPriceOrAmount_IsZero() external view {
        OracleQuote.Fx memory fx;
        fx.price = 1e8;
        fx.tokenDecimals = 18;
        fx.feedDecimals = 8;
        assertEq(quote.toUsd(fx, 0), 0);
        fx.price = 0;
        assertEq(quote.toUsd(fx, 1e18), 0);
    }

    function test_ToUsd_EighteenDecimalsAtOneDollar() external view {
        OracleQuote.Fx memory fx =
            OracleQuote.Fx({price: 1e8, quotedAt: 1, feedDecimals: 8, tokenDecimals: 18, fromCache: false, stale: false});
        assertEq(quote.toUsd(fx, 1e18), 1e8);
        assertEq(quote.toUsd(fx, 1_000e18), 1_000e8);
    }

    function test_PackUnpack_RoundTripsFlags() external view {
        OracleQuote.Fx memory fx = OracleQuote.Fx({
            price: 123e8,
            quotedAt: 1_700_000_042,
            feedDecimals: 8,
            tokenDecimals: 6,
            fromCache: true,
            stale: true
        });
        uint256 packed = quote.pack(fx);
        OracleQuote.Fx memory out = quote.unpack(fx.price, packed);
        assertEq(out.price, fx.price);
        assertEq(out.quotedAt, fx.quotedAt);
        assertEq(out.feedDecimals, fx.feedDecimals);
        assertEq(out.tokenDecimals, fx.tokenDecimals);
        assertTrue(out.fromCache);
        assertTrue(out.stale);
    }

    function test_PackUnpack_LiveFlagsStayClear() external view {
        OracleQuote.Fx memory fx = OracleQuote.Fx({
            price: 1e8,
            quotedAt: 8,
            feedDecimals: 8,
            tokenDecimals: 18,
            fromCache: false,
            stale: false
        });
        OracleQuote.Fx memory out = quote.unpack(fx.price, quote.pack(fx));
        assertFalse(out.fromCache);
        assertFalse(out.stale);
        assertEq(out.quotedAt, 8);
    }

    function test_TokenDecimalsOf_NativeAndNoCodeAre18() external view {
        (uint8 d0, bool ok0) = quote.tokenDecimalsOf(address(0));
        (uint8 dEoa, bool okEoa) = quote.tokenDecimalsOf(address(0xBEEF));
        assertTrue(ok0);
        assertTrue(okEoa);
        assertEq(d0, 18);
        assertEq(dEoa, 18);
    }

    function test_TokenDecimalsOf_ContractWithoutDecimals_FailsClosed() external {
        NoDecimalsToken bare = new NoDecimalsToken();
        (uint8 d, bool ok) = quote.tokenDecimalsOf(address(bare));
        assertFalse(ok);
        assertEq(d, 0);
    }

    function test_TokenDecimalsOf_SixDecimalToken() external {
        token.setDecimals(6);
        (uint8 d, bool ok) = quote.tokenDecimalsOf(address(token));
        assertTrue(ok);
        assertEq(d, 6);
    }

    function test_Resolve_NativeToken_UsesEighteenDecimals() external {
        quote.setFeed(address(0), address(feed));
        (OracleQuote.Fx memory fx, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(0));
        assertEq(err, bytes32(0));
        assertEq(fx.tokenDecimals, 18);
    }

    function test_Resolve_CacheQuotedAtZero_IsNotUsableFallback() external {
        quote.seedCache(address(token), 1e8, 0, 8, 18);
        quote.setFeed(address(token), address(0));
        (, bytes32 err) = quote.resolve(STALE_LIVE, MAX_STALE, address(token));
        assertEq(err, quote.noFeed());
    }
}
