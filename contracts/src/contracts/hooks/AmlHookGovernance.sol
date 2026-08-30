// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookGovernanceBase} from "./AmlHookGovernanceBase.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";
import {MultisigAggregation, MultisigType, TrustedMultisig} from "../../libraries/WalletSubject.sol";
import {IAggregatorV3} from "../../interfaces/external/IAggregatorV3.sol";

/// @title AmlHookGovernance — external configuration setters for compliance parameters
/// @notice Adds all tunable parameter setters on top of AmlHookGovernanceBase state.
///         The swap-evaluation path (AmlHookLogic) is read-only here.
///         Sensitive floor parameters require a compliance-officer proposal followed by a
///         governor `apply*` call (two-actor, two-step).
abstract contract AmlHookGovernance is AmlHookGovernanceBase {
    function setStalenessThreshold(uint256 stalenessThreshold_) external restricted {
        if (stalenessThreshold_ == 0) revert StalenessThresholdTooLow();
        if (stalenessThreshold_ > MAX_STALENESS) revert StalenessThresholdTooHigh();
        emit StalenessThresholdUpdated(stalenessThreshold, stalenessThreshold_);
        stalenessThreshold = stalenessThreshold_;
    }

    function setMinBaselineInterval(uint64 minBaselineInterval_) external restricted {
        if (minBaselineInterval_ == 0) revert BaselineIntervalZero();
        emit MinBaselineIntervalUpdated(minBaselineInterval, minBaselineInterval_);
        minBaselineInterval = minBaselineInterval_;
    }

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }

    function setInflowThresholdBps(uint256 inflowThresholdBps_) external restricted {
        if (inflowThresholdBps_ < FeeBps.MIN_INFLOW_THRESHOLD || inflowThresholdBps_ > FeeBps.MAX_INFLOW_THRESHOLD) {
            revert InflowThresholdOutOfRange();
        }
        emit InflowThresholdUpdated(inflowThresholdBps, inflowThresholdBps_);
        inflowThresholdBps = inflowThresholdBps_;
    }

    function proposePoolImpactThresholdBps(uint256 poolImpactThresholdBps_) external {
        _requireComplianceOfficer();
        _propose(_ID_IMPACT, poolImpactThresholdBps_, 0, poolImpactThresholdBps, 0);
        _emitProposed(PARAM_POOL_IMPACT_THRESHOLD_BPS, poolImpactThresholdBps, poolImpactThresholdBps_);
        _emitScheduled(PARAM_POOL_IMPACT_THRESHOLD_BPS, poolImpactThresholdBps, poolImpactThresholdBps_);
    }

    function applyPoolImpactThresholdBps(uint256 poolImpactThresholdBps_) external restricted {
        Pending memory p = _consume(_ID_IMPACT, poolImpactThresholdBps_, 0, PARAM_POOL_IMPACT_THRESHOLD_BPS);
        _emitConfirmed(PARAM_POOL_IMPACT_THRESHOLD_BPS, p.prevA, poolImpactThresholdBps_, p.proposer);
        emit PoolImpactThresholdUpdated(p.prevA, poolImpactThresholdBps_);
        poolImpactThresholdBps = poolImpactThresholdBps_;
    }

    function proposeUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) external {
        _requireComplianceOfficer();
        _validateUnscoredThresholds(feeThreshold, revertThreshold);
        _propose(_ID_UNSCORED, feeThreshold, revertThreshold, unscoredFeeThreshold, unscoredRevertThreshold);
        _emitProposed(PARAM_UNSCORED_FEE_THRESHOLD, unscoredFeeThreshold, feeThreshold);
        _emitProposed(PARAM_UNSCORED_REVERT_THRESHOLD, unscoredRevertThreshold, revertThreshold);
        _emitScheduled(PARAM_UNSCORED_FEE_THRESHOLD, unscoredFeeThreshold, feeThreshold);
        _emitScheduled(PARAM_UNSCORED_REVERT_THRESHOLD, unscoredRevertThreshold, revertThreshold);
    }

    function applyUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) external restricted {
        Pending memory p = _consume(_ID_UNSCORED, feeThreshold, revertThreshold, PARAM_UNSCORED_FEE_THRESHOLD);
        _validateUnscoredThresholds(feeThreshold, revertThreshold);
        _emitConfirmed(PARAM_UNSCORED_FEE_THRESHOLD, p.prevA, feeThreshold, p.proposer);
        _emitConfirmed(PARAM_UNSCORED_REVERT_THRESHOLD, p.prevB, revertThreshold, p.proposer);
        emit UnscoredThresholdsUpdated(p.prevA, p.prevB, feeThreshold, revertThreshold);
        unscoredFeeThreshold = feeThreshold;
        unscoredRevertThreshold = revertThreshold;
    }

    function proposeFloorFees(uint24 proportionalFeeBps_, uint24 punitiveFeeBps_) external {
        _requireComplianceOfficer();
        _validateFloorFees(proportionalFeeBps_, punitiveFeeBps_);
        _propose(_ID_FEES, proportionalFeeBps_, punitiveFeeBps_, proportionalFeeBps, punitiveFeeBps);
        _emitProposed(PARAM_PROPORTIONAL_FEE_BPS, proportionalFeeBps, proportionalFeeBps_);
        _emitProposed(PARAM_PUNITIVE_FEE_BPS, punitiveFeeBps, punitiveFeeBps_);
        _emitScheduled(PARAM_PROPORTIONAL_FEE_BPS, proportionalFeeBps, proportionalFeeBps_);
        _emitScheduled(PARAM_PUNITIVE_FEE_BPS, punitiveFeeBps, punitiveFeeBps_);
    }

    function applyFloorFees(uint24 proportionalFeeBps_, uint24 punitiveFeeBps_) external restricted {
        Pending memory p = _consume(_ID_FEES, proportionalFeeBps_, punitiveFeeBps_, PARAM_PROPORTIONAL_FEE_BPS);
        _validateFloorFees(proportionalFeeBps_, punitiveFeeBps_);
        _emitConfirmed(PARAM_PROPORTIONAL_FEE_BPS, p.prevA, proportionalFeeBps_, p.proposer);
        _emitConfirmed(PARAM_PUNITIVE_FEE_BPS, p.prevB, punitiveFeeBps_, p.proposer);
        proportionalFeeBps = proportionalFeeBps_;
        punitiveFeeBps = punitiveFeeBps_;
    }

    function setPriceFeed(address token, address feed) external restricted {
        address previous = address(priceFeeds[token]);
        priceFeeds[token] = IAggregatorV3(feed);
        emit PriceFeedUpdated(token, previous, feed);
    }

    function setActivityWindow(uint64 activityWindow_) external restricted {
        _applyActivityWindow(activityWindow_);
    }

    function setDailyWindow(uint64 dailyWindow_) external restricted {
        if (dailyWindow_ < MIN_DAILY_WINDOW || dailyWindow_ > MAX_DAILY_WINDOW) revert DailyWindowInvalid();
        emit DailyWindowUpdated(dailyWindow, dailyWindow_);
        dailyWindow = dailyWindow_;
    }

    function setPriceStalenessThreshold(uint256 priceStalenessThreshold_) external restricted {
        if (priceStalenessThreshold_ == 0 || priceStalenessThreshold_ > MAX_PRICE_STALENESS) {
            revert PriceStalenessThresholdInvalid();
        }
        emit PriceStalenessThresholdUpdated(priceStalenessThreshold, priceStalenessThreshold_);
        priceStalenessThreshold = priceStalenessThreshold_;
    }

    function setTrustedRouter(address router, bool trusted) external restricted {
        trustedRouters[router] = trusted;
        emit TrustedRouterUpdated(router, trusted);
    }

    function setTrustedMultisig(address account, MultisigType kind, bool trusted) external restricted {
        if (account == address(0)) revert MissingSwapSubject();
        if (trusted && kind == MultisigType.NONE) revert MissingSwapSubject();
        trustedMultisigs[account] = TrustedMultisig({trusted: trusted, kind: trusted ? kind : MultisigType.NONE});
        emit TrustedMultisigUpdated(account, kind, trusted);
    }

    function setMultisigAggregation(MultisigAggregation aggregation) external restricted {
        emit MultisigAggregationUpdated(multisigAggregation, aggregation);
        multisigAggregation = aggregation;
    }
}
