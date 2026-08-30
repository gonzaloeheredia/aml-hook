// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice MOCK Chainlink AggregatorV3 for local Anvil deploys (USD-8 quotes).
/// @dev Deploy-time tooling under script/mocks. Off the on-chain app surface.
contract MockUsdFeed {
    uint8 public decimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(int256 answer_) {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setRound(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
