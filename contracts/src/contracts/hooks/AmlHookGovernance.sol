// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IAggregatorV3} from "../../interfaces/external/IAggregatorV3.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";
import {Roles} from "../../libraries/Roles.sol";
import {MultisigAggregation, MultisigType, TrustedMultisig} from "../../libraries/WalletSubject.sol";

/// @title Hook config + two-step compliance-officer knobs. No swap evaluation.
abstract contract AmlHookGovernance is AccessManaged, Pausable {
    ISanctionRegistry public immutable sanctionRegistry;
    IComplianceOracle public immutable complianceOracle;
    IRiskPolicy public immutable riskPolicy;

    mapping(address => bool) public trustedRouters;
    mapping(address => TrustedMultisig) public trustedMultisigs;
    mapping(address => IAggregatorV3) public priceFeeds;

    MultisigAggregation public multisigAggregation = MultisigAggregation.ALL_CLEAN;

    uint256 public stalenessThreshold;
    uint256 public constant DEFAULT_STALENESS = 5 minutes;
    uint256 public constant MAX_STALENESS = 24 hours;

    uint64 public minBaselineInterval = 1 hours;
    uint64 public activityWindow;
    uint64 public dailyWindow;
    uint256 public priceStalenessThreshold;
    uint256 public inflowThresholdBps;
    uint256 public unscoredFeeThreshold;
    uint256 public unscoredRevertThreshold;
    uint256 public poolImpactThresholdBps;
    uint24 public proportionalFeeBps;
    uint24 public punitiveFeeBps;

    uint64 public constant DEFAULT_ACTIVITY_WINDOW = 1 hours;
    uint64 public constant DEFAULT_DAILY_WINDOW = 24 hours;
    uint64 public constant MIN_ACTIVITY_WINDOW = 60;
    uint64 public constant MAX_ACTIVITY_WINDOW = 7 days;
    uint64 public constant MIN_DAILY_WINDOW = 1 hours;
    uint64 public constant MAX_DAILY_WINDOW = 7 days;
    uint256 public constant DEFAULT_USD_FEE_THRESHOLD = 1_000e8;
    uint256 public constant DEFAULT_USD_REVERT_THRESHOLD = 15_000e8;
    uint256 public constant MIN_UNSCORED_FEE_THRESHOLD = 1_000e8;
    uint256 public constant DEFAULT_PRICE_STALENESS = 3600;
    uint256 public constant MAX_PRICE_STALENESS = 24 hours;
    uint256 public constant DEFAULT_POOL_IMPACT_THRESHOLD_BPS = 2000;
    uint24 public constant LATENCY_FEE_BPS = FeeBps.LATENCY;

    string public constant PARAM_UNSCORED_FEE_THRESHOLD = "unscoredFeeThreshold";
    string public constant PARAM_UNSCORED_REVERT_THRESHOLD = "unscoredRevertThreshold";
    string public constant PARAM_POOL_IMPACT_THRESHOLD_BPS = "poolImpactThresholdBps";
    string public constant PARAM_PROPORTIONAL_FEE_BPS = "proportionalFeeBps";
    string public constant PARAM_PUNITIVE_FEE_BPS = "punitiveFeeBps";

    struct Pending {
        uint256 a;
        uint256 b;
        uint256 prevA;
        uint256 prevB;
        address proposer;
        bool exists;
    }

    bytes32 private constant _ID_UNSCORED = keccak256("unscored");
    bytes32 private constant _ID_IMPACT = keccak256("poolImpact");
    bytes32 private constant _ID_FEES = keccak256("floorFees");
    mapping(bytes32 => Pending) private _pending;

    error UnscoredFeeThresholdBelowFatfMinimum(uint256 feeThreshold, uint256 minimum);
    error UnscoredRevertMustExceedFee(uint256 feeThreshold, uint256 revertThreshold);
    error PunitiveFeeMustExceedProportional(uint24 proportionalFeeBps, uint24 punitiveFeeBps);
    error NoPendingPolicyParam(string name);
    error PendingPolicyParamMismatch(string name);
    error PriceStalenessThresholdInvalid();
    error ActivityWindowInvalid();
    error DailyWindowInvalid();
    error InflowThresholdOutOfRange();
    error StalenessThresholdTooLow();
    error StalenessThresholdTooHigh();
    error BaselineIntervalZero();
    error MissingSwapSubject();

    event MinBaselineIntervalUpdated(uint64 previous, uint64 current);
    event TrustedMultisigUpdated(address indexed account, MultisigType kind, bool trusted);
    event MultisigAggregationUpdated(MultisigAggregation previous, MultisigAggregation current);
    event StalenessThresholdUpdated(uint256 previous, uint256 current);
    event InflowThresholdUpdated(uint256 previous, uint256 current);
    event PolicyParamProposed(string name, uint256 previousValue, uint256 newValue, address indexed actor);
    event PolicyParamScheduled(
        string name, uint256 previousValue, uint256 newValue, address indexed actor, uint48 readyAt
    );
    event PolicyParamConfirmed(string name, uint256 previousValue, uint256 newValue, address indexed actor);
    event PoolImpactThresholdUpdated(uint256 previous, uint256 current);
    event UnscoredThresholdsUpdated(
        uint256 previousFeeThreshold, uint256 previousRevertThreshold, uint256 feeThreshold, uint256 revertThreshold
    );
    event PriceFeedUpdated(address indexed token, address previousFeed, address feed);
    event PriceStalenessThresholdUpdated(uint256 previous, uint256 current);
    event ActivityWindowUpdated(uint64 previous, uint64 current);
    event DailyWindowUpdated(uint64 previousWindow, uint64 dailyWindow);
    event TrustedRouterUpdated(address indexed router, bool trusted);

    constructor(
        address accessManager_,
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        uint256 stalenessThreshold_,
        uint64 activityWindow_
    ) AccessManaged(accessManager_) {
        sanctionRegistry = sanctionRegistry_;
        complianceOracle = complianceOracle_;
        riskPolicy = riskPolicy_;
        if (stalenessThreshold_ == 0) {
            stalenessThreshold = DEFAULT_STALENESS;
        } else {
            if (stalenessThreshold_ > MAX_STALENESS) revert StalenessThresholdTooHigh();
            stalenessThreshold = stalenessThreshold_;
        }
        _applyActivityWindow(activityWindow_ == 0 ? DEFAULT_ACTIVITY_WINDOW : activityWindow_);
        dailyWindow = DEFAULT_DAILY_WINDOW;
        inflowThresholdBps = 5000;
        unscoredFeeThreshold = DEFAULT_USD_FEE_THRESHOLD;
        unscoredRevertThreshold = DEFAULT_USD_REVERT_THRESHOLD;
        proportionalFeeBps = FeeBps.PROPORTIONAL;
        punitiveFeeBps = FeeBps.PUNITIVE;
        priceStalenessThreshold = DEFAULT_PRICE_STALENESS;
        poolImpactThresholdBps = DEFAULT_POOL_IMPACT_THRESHOLD_BPS;
        emit DailyWindowUpdated(0, dailyWindow);
        emit StalenessThresholdUpdated(0, stalenessThreshold);
        emit PoolImpactThresholdUpdated(0, poolImpactThresholdBps);
        emit InflowThresholdUpdated(0, inflowThresholdBps);
        emit UnscoredThresholdsUpdated(0, 0, unscoredFeeThreshold, unscoredRevertThreshold);
        emit PriceStalenessThresholdUpdated(0, priceStalenessThreshold);
    }

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
    }

    function applyPoolImpactThresholdBps(uint256 poolImpactThresholdBps_) external restricted {
        Pending memory p = _consume(_ID_IMPACT, poolImpactThresholdBps_, 0, PARAM_POOL_IMPACT_THRESHOLD_BPS);
        emit PolicyParamConfirmed(PARAM_POOL_IMPACT_THRESHOLD_BPS, p.prevA, poolImpactThresholdBps_, p.proposer);
        emit PoolImpactThresholdUpdated(p.prevA, poolImpactThresholdBps_);
        poolImpactThresholdBps = poolImpactThresholdBps_;
    }

    function proposeUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) external {
        _requireComplianceOfficer();
        _validateUnscoredThresholds(feeThreshold, revertThreshold);
        _propose(_ID_UNSCORED, feeThreshold, revertThreshold, unscoredFeeThreshold, unscoredRevertThreshold);
        _emitProposed(PARAM_UNSCORED_FEE_THRESHOLD, unscoredFeeThreshold, feeThreshold);
        _emitProposed(PARAM_UNSCORED_REVERT_THRESHOLD, unscoredRevertThreshold, revertThreshold);
    }

    function applyUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) external restricted {
        Pending memory p = _consume(_ID_UNSCORED, feeThreshold, revertThreshold, PARAM_UNSCORED_FEE_THRESHOLD);
        _validateUnscoredThresholds(feeThreshold, revertThreshold);
        emit PolicyParamConfirmed(PARAM_UNSCORED_FEE_THRESHOLD, p.prevA, feeThreshold, p.proposer);
        emit PolicyParamConfirmed(PARAM_UNSCORED_REVERT_THRESHOLD, p.prevB, revertThreshold, p.proposer);
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
    }

    function applyFloorFees(uint24 proportionalFeeBps_, uint24 punitiveFeeBps_) external restricted {
        Pending memory p = _consume(_ID_FEES, proportionalFeeBps_, punitiveFeeBps_, PARAM_PROPORTIONAL_FEE_BPS);
        _validateFloorFees(proportionalFeeBps_, punitiveFeeBps_);
        emit PolicyParamConfirmed(PARAM_PROPORTIONAL_FEE_BPS, p.prevA, proportionalFeeBps_, p.proposer);
        emit PolicyParamConfirmed(PARAM_PUNITIVE_FEE_BPS, p.prevB, punitiveFeeBps_, p.proposer);
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

    function _requireComplianceOfficer() private view {
        (bool isMember,) = IAccessManager(authority()).hasRole(Roles._COMPLIANCE_OFFICER, msg.sender);
        if (!isMember) revert IAccessManaged.AccessManagedUnauthorized(msg.sender);
    }

    function _emitProposed(string memory name, uint256 previousValue, uint256 newValue) private {
        emit PolicyParamProposed(name, previousValue, newValue, msg.sender);
        (, uint32 delay) = IAccessManager(authority()).hasRole(Roles._COMPLIANCE_OFFICER, msg.sender);
        emit PolicyParamScheduled(name, previousValue, newValue, msg.sender, uint48(block.timestamp) + delay);
    }

    function _propose(bytes32 id, uint256 a, uint256 b, uint256 prevA, uint256 prevB) private {
        _pending[id] = Pending(a, b, prevA, prevB, msg.sender, true);
    }

    function _consume(bytes32 id, uint256 a, uint256 b, string memory name) private returns (Pending memory p) {
        p = _pending[id];
        if (!p.exists) revert NoPendingPolicyParam(name);
        if (p.a != a || p.b != b) revert PendingPolicyParamMismatch(name);
        delete _pending[id];
    }

    function _validateUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) private pure {
        if (feeThreshold < MIN_UNSCORED_FEE_THRESHOLD) {
            revert UnscoredFeeThresholdBelowFatfMinimum(feeThreshold, MIN_UNSCORED_FEE_THRESHOLD);
        }
        if (revertThreshold <= feeThreshold) revert UnscoredRevertMustExceedFee(feeThreshold, revertThreshold);
    }

    function _validateFloorFees(uint24 proportionalFeeBps_, uint24 punitiveFeeBps_) private pure {
        if (punitiveFeeBps_ <= proportionalFeeBps_) {
            revert PunitiveFeeMustExceedProportional(proportionalFeeBps_, punitiveFeeBps_);
        }
    }

    function _applyActivityWindow(uint64 activityWindow_) private {
        if (activityWindow_ < MIN_ACTIVITY_WINDOW || activityWindow_ > MAX_ACTIVITY_WINDOW) {
            revert ActivityWindowInvalid();
        }
        emit ActivityWindowUpdated(activityWindow, activityWindow_);
        activityWindow = activityWindow_;
    }
}
