// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Chainlink AggregatorV3 surface used to quote specified-currency amounts in USD.
/// @dev Same selectors as `@chainlink/contracts` AggregatorV3Interface. We keep a local copy so
///      the hook does not depend on the Chainlink package at compile time.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
