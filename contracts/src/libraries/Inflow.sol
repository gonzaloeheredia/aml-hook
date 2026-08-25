// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "../interfaces/external/IERC20Minimal.sol";

/// @title Inflow — Mitigation D pre-swap inbound token delta detector
/// @notice Compares the wallet's current ERC-20 balance against the last-known baseline to detect
///         a significant inflow that may have arrived since the score was last written.
library Inflow {
    /// @notice Compute the inflow signal for `wallet` on `token`.
    /// @dev Signal is skipped (returns false) when:
    ///      - `token` is address(0) or has no code (native / non-ERC-20).
    ///      - Current balance is zero.
    ///      - Score was never written (`scoreUpdatedAt == 0`): returns the full balance as delta
    ///        so the caller can apply a never-scored override; `hasSignificantInflow` is still false.
    ///      - No baseline exists yet (`baselineTimestamp == 0`).
    ///      - Score was written after the baseline (`scoreUpdatedAt > baselineTimestamp`):
    ///        the oracle already accounts for the inflow; skip the heuristic.
    ///      Share (`inflowShareBps`) is computed in token-native units here;
    ///      `AmlHookLogic._fillUsd` overwrites it with the USD-denominated share.
    /// @param wallet                   Compliance subject.
    /// @param token                    ERC-20 token to inspect.
    /// @param scoreUpdatedAt           `WalletRisk.updatedAt` from the oracle (0 = never written).
    /// @param lastKnownBalance         Stored baselines per wallet per token.
    /// @param lastKnownBalanceTimestamp Timestamps of stored baselines.
    /// @param inflowThresholdBps       Bps above which the inflow is "significant".
    /// @return hasSignificantInflow True when inflow share exceeds the threshold and the heuristic applies.
    /// @return inflowShareBps       Inflow as a fraction of current balance (bps), or 0 when skipped.
    /// @return inflowTokenDelta     Raw token units of the inflow (0 when heuristic is skipped).
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
