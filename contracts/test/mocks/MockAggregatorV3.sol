// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Chainlink AggregatorV3 stand-in for unit tests.
contract MockAggregatorV3 {
    uint8 public decimals = 8;
    int256 public answer = 1e8;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    bool public revertOnRead;

    constructor() {
        updatedAt = block.timestamp;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    function setRound(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setAnsweredInRound(uint80 answeredInRound_) external {
        answeredInRound = answeredInRound_;
    }

    function setRevertOnRead(bool revertOnRead_) external {
        revertOnRead = revertOnRead_;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        if (revertOnRead) revert();
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
