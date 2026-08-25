// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "../interfaces/external/IERC20Minimal.sol";

/// @title Mitigation D — inbound token delta vs last-known baseline.
library Inflow {
    /// @dev Never-written score: the whole bag is inbound. Published score newer than baseline: skip.
    ///      Share is a token-unit provisional; the hook overwrites with USD / current USD.
    function signal(
        address wallet,
        address token,
        uint64 scoreUpdatedAt,
        mapping(address => mapping(address => uint256)) storage lastKnownBalance,
        mapping(address => mapping(address => uint256)) storage lastKnownBalanceTimestamp,
        uint256 inflowThresholdBps
    ) internal view returns (bool hasSignificantInflow, uint256 inflowShareBps, uint256 inflowTokenDelta) {
        if (token == address(0) || token.code.length == 0) return (false, 0, 0);

        uint256 currentBalance = IERC20Minimal(token).balanceOf(wallet);
        if (currentBalance == 0) return (false, 0, 0);

        uint256 previousBalance = lastKnownBalance[wallet][token];
        uint256 balanceDelta = currentBalance > previousBalance ? currentBalance - previousBalance : 0;
        inflowShareBps = (balanceDelta * 10_000) / currentBalance;

        uint256 baselineTimestamp = lastKnownBalanceTimestamp[wallet][token];
        if (scoreUpdatedAt == 0) return (false, inflowShareBps, currentBalance);
        if (baselineTimestamp == 0) return (false, 0, 0);
        if (uint256(scoreUpdatedAt) > baselineTimestamp) return (false, inflowShareBps, 0);

        inflowTokenDelta = balanceDelta;
        if (inflowShareBps > inflowThresholdBps) hasSignificantInflow = true;
    }
}
