// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Always-fresh AggregatorV3 for Sepolia demo FX (1 MockETH = 1,000 MockUSD).
/// @dev `updatedAt` is `block.timestamp` so `OracleQuote` never fail-closes on staleness.
contract DemoUsdFeed {
    uint8 public constant decimals = 8;
    int256 public immutable answer;

    constructor(int256 answer_) {
        require(answer_ > 0, "answer");
        answer = answer_;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, answer, 0, block.timestamp, 1);
    }
}
