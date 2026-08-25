// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookDecision} from "../../libraries/HookDecision.sol";

/// @title Layer 3 — pure mapping from score + floor signals → ALLOW / FEE_OVERRIDE / REVERT.
interface IRiskPolicy {
    enum RevertKind {
        None,
        ScoreBand,
        UnscoredMagnitude,
        UnscoredPoolImpact,
        DailyAggregation
    }

    struct DecisionInput {
        uint8 score;
        uint24 recommendedFeeBps;
        bool isStale;
        uint32 operationCount;
        bool neverScored;
        uint256 assessedUsd;
        uint256 inflowUsd;
        uint256 unscoredFeeThreshold;
        uint256 unscoredRevertThreshold;
        uint24 proportionalFeeBps;
        uint24 punitiveFeeBps;
        uint256 poolImpactBps;
        uint256 poolImpactThresholdBps;
        uint256 priorDailyUsd;
        uint256 swapUsd;
    }

    struct DecisionResult {
        HookDecision decision;
        uint24 feeBps;
        RevertKind revertKind;
    }

    /// @notice Single mapping for score bands plus floors A–D (USD, pool-impact extra, daily aggregation).
    function decide(DecisionInput calldata input) external pure returns (DecisionResult memory);
}
