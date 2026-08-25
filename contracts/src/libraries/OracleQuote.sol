// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAggregatorV3} from "../interfaces/external/IAggregatorV3.sol";
import {IERC20Minimal} from "../interfaces/external/IERC20Minimal.sol";
import {UsdQuote} from "./UsdQuote.sol";

/// @title Chainlink USD-8 quotes for hook magnitude floors.
/// @dev Skip the aggregator when `lastFx` is younger than `HOT_TTL` (30 minutes). Otherwise one
///      `latestRoundData` per token; a usable live round is cached. If the live read fails, `lastFx`
///      still sizes this swap until `maxPriceStaleness` (24h).
library OracleQuote {
    bytes32 internal constant NO_FEED = keccak256("NO_FEED");
    bytes32 internal constant STALE_FEED = keccak256("STALE_FEED");
    bytes32 internal constant BAD_PRICE = keccak256("BAD_PRICE");
    bytes32 internal constant WINDOW_FAILED = keccak256("WINDOW_FAILED");
    uint256 internal constant HOT_TTL = 30 minutes;

    struct CachedFx {
        uint256 price;
        uint64 quotedAt;
        uint8 feedDecimals;
        uint8 tokenDecimals;
    }

    struct Fx {
        uint256 price;
        uint64 quotedAt;
        uint8 feedDecimals;
        uint8 tokenDecimals;
        bool fromCache;
        bool stale;
    }

    /// @dev Hot `lastFx` (< 30m) skips Chainlink. Else live round, else cache until 24h.
    function resolve(
        mapping(address => IAggregatorV3) storage priceFeeds,
        mapping(address => CachedFx) storage lastFx,
        uint256 priceStalenessThreshold,
        uint256 maxPriceStaleness,
        address token
    ) internal view returns (Fx memory fx, bytes32 err) {
        CachedFx storage cached = lastFx[token];
        if (_isHot(cached)) return (_asHot(cached), bytes32(0));
        (Fx memory live, bytes32 liveErr) = _readLive(priceFeeds[token], token, priceStalenessThreshold);
        if (liveErr == bytes32(0)) return (live, bytes32(0));
        return _fromCache(cached, maxPriceStaleness, liveErr);
    }

    /// @dev Persist a live round. Never writes a cache hit or a zero price.
    function commit(mapping(address => CachedFx) storage lastFx, address token, Fx memory fx) internal {
        if (fx.fromCache || fx.price == 0) return;
        lastFx[token] = CachedFx({
            price: fx.price,
            quotedAt: fx.quotedAt,
            feedDecimals: fx.feedDecimals,
            tokenDecimals: fx.tokenDecimals
        });
    }

    function toUsd(Fx memory fx, uint256 amount) internal pure returns (uint256) {
        if (fx.price == 0 || amount == 0) return 0;
        return UsdQuote.toUsd8(amount, fx.tokenDecimals, fx.price, fx.feedDecimals);
    }

    function pack(Fx memory fx) internal pure returns (uint256 p) {
        p = uint256(fx.tokenDecimals) | (uint256(fx.feedDecimals) << 8) | (uint256(fx.fromCache ? 1 : 0) << 16)
            | (uint256(fx.stale ? 1 : 0) << 17) | (uint256(fx.quotedAt) << 24);
    }

    function unpack(uint256 price, uint256 packed) internal pure returns (Fx memory fx) {
        fx.price = price;
        fx.tokenDecimals = uint8(packed);
        fx.feedDecimals = uint8(packed >> 8);
        fx.fromCache = uint8(packed >> 16) != 0;
        fx.stale = uint8(packed >> 17) != 0;
        fx.quotedAt = uint64(packed >> 24);
    }

    function _fromCache(CachedFx storage cached, uint256 maxPriceStaleness, bytes32 liveErr)
        private
        view
        returns (Fx memory fx, bytes32 err)
    {
        if (cached.price == 0 || cached.quotedAt == 0) return (fx, liveErr);
        if (block.timestamp > uint256(cached.quotedAt) + maxPriceStaleness) return (fx, STALE_FEED);
        fx.price = cached.price;
        fx.quotedAt = cached.quotedAt;
        fx.feedDecimals = cached.feedDecimals;
        fx.tokenDecimals = cached.tokenDecimals;
        fx.fromCache = true;
        fx.stale = true;
    }

    function _isHot(CachedFx storage cached) private view returns (bool) {
        if (cached.price == 0 || cached.quotedAt == 0) return false;
        return block.timestamp <= uint256(cached.quotedAt) + HOT_TTL;
    }

    function _asHot(CachedFx storage cached) private view returns (Fx memory fx) {
        fx.price = cached.price;
        fx.quotedAt = cached.quotedAt;
        fx.feedDecimals = cached.feedDecimals;
        fx.tokenDecimals = cached.tokenDecimals;
        fx.fromCache = true;
    }

    function _readLive(IAggregatorV3 feed, address token, uint256 priceStalenessThreshold)
        private
        view
        returns (Fx memory fx, bytes32 err)
    {
        if (address(feed) == address(0)) return (fx, NO_FEED);

        (uint80 roundId, int256 price, uint256 updatedAt, uint80 answeredInRound, bool ok) = _latestRound(feed);
        if (!ok) return (fx, BAD_PRICE);
        if (price <= 0 || updatedAt == 0 || answeredInRound < roundId) return (fx, BAD_PRICE);

        uint8 feedDecimals;
        try feed.decimals() returns (uint8 decimals) {
            feedDecimals = decimals;
        } catch {
            return (fx, BAD_PRICE);
        }
        if (feedDecimals > 18) return (fx, BAD_PRICE);

        (uint8 tokenDecimals, bool decOk) = tokenDecimalsOf(token);
        if (!decOk) return (fx, BAD_PRICE);

        fx.price = uint256(price);
        fx.quotedAt = uint64(updatedAt);
        fx.feedDecimals = feedDecimals;
        fx.tokenDecimals = tokenDecimals;
        fx.stale = block.timestamp > updatedAt + priceStalenessThreshold;
    }

    /// @dev Isolated so `latestRoundData`'s 5-value ABI decode does not share a frame with quote math.
    function _latestRound(IAggregatorV3 feed)
        private
        view
        returns (uint80 roundId, int256 price, uint256 updatedAt, uint80 answeredInRound, bool ok)
    {
        try feed.latestRoundData() returns (uint80 rid, int256 p, uint256, uint256 u, uint80 air) {
            return (rid, p, u, air, true);
        } catch {
            return (0, 0, 0, 0, false);
        }
    }

    /// @dev Native ETH and no-code currencies are 18 decimals. ERC-20 `decimals()` fail-closed if missing or > 36.
    function tokenDecimalsOf(address token) internal view returns (uint8 decimals_, bool ok) {
        if (token == address(0) || token.code.length == 0) return (18, true);
        try IERC20Minimal(token).decimals() returns (uint8 d) {
            if (d > 36) return (0, false);
            return (d, true);
        } catch {
            return (0, false);
        }
    }
}
