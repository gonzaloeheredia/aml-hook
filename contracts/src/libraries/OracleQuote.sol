// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAggregatorV3} from "../interfaces/external/IAggregatorV3.sol";
import {IERC20Minimal} from "../interfaces/external/IERC20Minimal.sol";
import {UsdQuote} from "./UsdQuote.sol";

/// @title Chainlink USD-8 quotes for hook magnitude floors.
library OracleQuote {
    bytes32 internal constant NO_FEED = keccak256("NO_FEED");
    bytes32 internal constant STALE_FEED = keccak256("STALE_FEED");
    bytes32 internal constant BAD_PRICE = keccak256("BAD_PRICE");
    bytes32 internal constant WINDOW_FAILED = keccak256("WINDOW_FAILED");

    /// @dev Missing, stale, or invalid feed → `quoteError` set, `usd` = 0. Never reverts.
    function tryQuote(
        mapping(address => IAggregatorV3) storage priceFeeds,
        uint256 priceStalenessThreshold,
        address token,
        uint256 amount
    ) internal view returns (uint256 usd, bytes32 quoteError) {
        IAggregatorV3 feed = priceFeeds[token];
        if (address(feed) == address(0)) return (0, NO_FEED);

        uint80 roundId;
        int256 price;
        uint256 updatedAt;
        uint80 answeredInRound;
        try feed.latestRoundData() returns (uint80 rid, int256 p, uint256, uint256 u, uint80 air) {
            roundId = rid;
            price = p;
            updatedAt = u;
            answeredInRound = air;
        } catch {
            return (0, BAD_PRICE);
        }

        if (price <= 0 || updatedAt == 0 || answeredInRound < roundId) return (0, BAD_PRICE);
        if (block.timestamp > updatedAt + priceStalenessThreshold) return (0, STALE_FEED);

        uint8 feedDecimals;
        try feed.decimals() returns (uint8 decimals) {
            feedDecimals = decimals;
        } catch {
            return (0, BAD_PRICE);
        }
        if (feedDecimals > 18) return (0, BAD_PRICE);

        (uint8 tokenDecimals, bool decOk) = tokenDecimalsOf(token);
        if (!decOk) return (0, BAD_PRICE);

        usd = UsdQuote.toUsd8(amount, tokenDecimals, uint256(price), feedDecimals);
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
