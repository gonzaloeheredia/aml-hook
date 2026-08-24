// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IAggregatorV3} from "interfaces/external/IAggregatorV3.sol";
import {ChainlinkFeeds} from "libraries/ChainlinkFeeds.sol";
import {UsdQuote} from "libraries/UsdQuote.sol";

/// @notice Live Chainlink quote when MAINNET_RPC_URL is set; otherwise address-table only.
contract UnitChainlinkFeedsLiveTest is Test {
    function test_MainnetFork_OneEthQuotesThroughOfficialEthUsdFeed() external {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        IAggregatorV3 feed = IAggregatorV3(ChainlinkFeeds.ethUsd(1));
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertGt(answer, 0);
        assertGt(updatedAt, 0);
        assertEq(feed.decimals(), 8);

        uint256 usd8 = UsdQuote.toUsd8(1 ether, 18, uint256(answer), 8);
        assertGt(usd8, 100e8);
        assertLt(usd8, 1_000_000e8);
    }

    function test_MainnetFork_OneUsdcQuotesNearOneDollar() external {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        IAggregatorV3 feed = IAggregatorV3(ChainlinkFeeds.usdcUsd(1));
        (, int256 answer,,,) = feed.latestRoundData();
        assertGt(answer, 0);
        uint256 usd8 = UsdQuote.toUsd8(1e6, 6, uint256(answer), feed.decimals());
        assertGt(usd8, 95e7);
        assertLt(usd8, 105e7);
    }
}
