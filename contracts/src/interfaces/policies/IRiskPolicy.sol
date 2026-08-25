// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookDecision} from "../../libraries/HookDecision.sol";

/// @title IRiskPolicy — Layer 3 pure mapping: score + floor signals → ALLOW / FEE_OVERRIDE / REVERT
interface IRiskPolicy {
    /// @notice Discriminator for the revert path — tells the hook which error to emit.
    enum RevertKind {
        None,                // not a revert
        ScoreBand,           // score ≥ 71
        UnscoredMagnitude,   // never-scored wallet at or above the USD revert threshold
        UnscoredPoolImpact,  // never-scored wallet draining the pool at punitive-fee level
        DailyAggregation     // rolling daily USD met or exceeded the revert threshold
    }

    /// @notice Packed signal set passed from `AmlHookLogic` to `RiskPolicyLib.decide`.
    struct DecisionInput {
        uint8 score;                    // 0–100 behavioral score (0 = never written when neverScored = true)
        uint24 recommendedFeeBps;       // keeper-recommended fee for score 31–70 (capped at MAX_OVERRIDE)
        bool isStale;                   // true when score age exceeds `stalenessThreshold`
        uint32 operationCount;          // swaps in the current `activityWindow`
        bool neverScored;               // true when oracle `updatedAt == 0`
        uint256 assessedUsd;            // 8-decimal USD for magnitude floors (window + this swap)
        uint256 inflowUsd;              // 8-decimal USD value of the Mitigation D inflow
        uint256 unscoredFeeThreshold;   // USD below which unscored pays proportional fee
        uint256 unscoredRevertThreshold;// USD at/above which unscored is reverted
        uint24 proportionalFeeBps;      // live proportional floor fee
        uint24 punitiveFeeBps;          // live punitive floor fee
        uint256 poolImpactBps;          // this swap's pool impact in bps
        uint256 poolImpactThresholdBps; // threshold above which pool-drain hardening applies
        uint256 priorDailyUsd;          // rolling daily USD before this swap
        uint256 swapUsd;                // USD value of this swap alone (daily aggregation check)
    }

    /// @notice Decision output returned by `decide` / `RiskPolicyLib.decide`.
    struct DecisionResult {
        HookDecision decision;   // ALLOW / FEE_OVERRIDE / REVERT
        uint24 feeBps;           // override fee in bps (0 on ALLOW / REVERT)
        RevertKind revertKind;   // discriminator for the revert error (None when decision ≠ REVERT)
    }

    /// @notice Evaluate the full signal set and return the compliance decision.
    /// @dev Off-chain preview only. The swap hot path calls `RiskPolicyLib.decide` directly
    ///      (one memory pointer, no external CALL) to avoid the gas overhead.
    function decide(DecisionInput calldata input) external pure returns (DecisionResult memory);
}
