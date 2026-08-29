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
import {OracleQuote} from "../../libraries/OracleQuote.sol";
import {Roles} from "../../libraries/Roles.sol";
import {MultisigAggregation, MultisigType, TrustedMultisig} from "../../libraries/WalletSubject.sol";

/// @title AmlHookGovernanceBase — state, constants, events, errors, and initialisation for governance
/// @notice Shared base inherited by both AmlHookActivity (read path) and AmlHookGovernance (setters).
///         No external setter functions live here; they are added by AmlHookGovernance.
abstract contract AmlHookGovernanceBase is AccessManaged, Pausable {
    ISanctionRegistry public sanctionRegistry;
    IComplianceOracle public complianceOracle;
    IRiskPolicy public riskPolicy;

    mapping(address => bool) public trustedRouters;
    mapping(address => TrustedMultisig) public trustedMultisigs;
    mapping(address => IAggregatorV3) public priceFeeds;
    mapping(address => OracleQuote.CachedFx) public lastFx;

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
    uint256 public constant FX_HOT_TTL = 30 minutes;
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

    bytes32 internal constant _ID_UNSCORED = keccak256("unscored");
    bytes32 internal constant _ID_IMPACT = keccak256("poolImpact");
    bytes32 internal constant _ID_FEES = keccak256("floorFees");
    mapping(bytes32 => Pending) internal _pending;

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
    event PriceFallbackUsed(address indexed token, uint256 price, uint64 quotedAt, bool fromCache, bool stale);
    event PriceStalenessThresholdUpdated(uint256 previous, uint256 current);
    event ActivityWindowUpdated(uint64 previous, uint64 current);
    event DailyWindowUpdated(uint64 previousWindow, uint64 dailyWindow);
    event TrustedRouterUpdated(address indexed router, bool trusted);

    constructor(address accessManager_) AccessManaged(accessManager_) {}

    function _initGovernance(
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        uint256 stalenessThreshold_,
        uint64 activityWindow_
    ) internal {
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

    function _applyActivityWindow(uint64 activityWindow_) internal {
        if (activityWindow_ < MIN_ACTIVITY_WINDOW || activityWindow_ > MAX_ACTIVITY_WINDOW) {
            revert ActivityWindowInvalid();
        }
        emit ActivityWindowUpdated(activityWindow, activityWindow_);
        activityWindow = activityWindow_;
    }

    function _requireComplianceOfficer() internal view {
        (bool isMember,) = IAccessManager(authority()).hasRole(Roles._COMPLIANCE_OFFICER, msg.sender);
        if (!isMember) revert IAccessManaged.AccessManagedUnauthorized(msg.sender);
    }

    function _emitProposed(string memory name, uint256 previousValue, uint256 newValue) internal {
        emit PolicyParamProposed(name, previousValue, newValue, msg.sender);
    }

    function _emitScheduled(string memory name, uint256 previousValue, uint256 newValue) internal {
        (, uint32 delay) = IAccessManager(authority()).hasRole(Roles._COMPLIANCE_OFFICER, msg.sender);
        emit PolicyParamScheduled(name, previousValue, newValue, msg.sender, uint48(block.timestamp) + delay);
    }

    function _emitConfirmed(string memory name, uint256 previousValue, uint256 newValue, address actor) internal {
        emit PolicyParamConfirmed(name, previousValue, newValue, actor);
    }

    function _propose(bytes32 id, uint256 a, uint256 b, uint256 prevA, uint256 prevB) internal {
        _pending[id] = Pending(a, b, prevA, prevB, msg.sender, true);
    }

    function _consume(bytes32 id, uint256 a, uint256 b, string memory name) internal returns (Pending memory p) {
        p = _pending[id];
        if (!p.exists) revert NoPendingPolicyParam(name);
        if (p.a != a || p.b != b) revert PendingPolicyParamMismatch(name);
        delete _pending[id];
    }

    function _validateUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) internal pure {
        if (feeThreshold < MIN_UNSCORED_FEE_THRESHOLD) {
            revert UnscoredFeeThresholdBelowFatfMinimum(feeThreshold, MIN_UNSCORED_FEE_THRESHOLD);
        }
        if (revertThreshold <= feeThreshold) revert UnscoredRevertMustExceedFee(feeThreshold, revertThreshold);
    }

    function _validateFloorFees(uint24 proportionalFeeBps_, uint24 punitiveFeeBps_) internal pure {
        if (punitiveFeeBps_ <= proportionalFeeBps_) {
            revert PunitiveFeeMustExceedProportional(proportionalFeeBps_, punitiveFeeBps_);
        }
    }
}
