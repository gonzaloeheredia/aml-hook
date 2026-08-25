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

/// @title AmlHookGovernance — configuration and two-step compliance-officer parameter knobs
/// @notice Owns all tunable parameters. The swap-evaluation path (AmlHookLogic) is read-only here.
///         Sensitive floor parameters (unscored thresholds, pool-impact, floor fees) require a
///         compliance-officer proposal followed by a governor `apply*` call (two-actor, two-step).
abstract contract AmlHookGovernance is AccessManaged, Pausable {
    /// @notice Layer 1 sanctions list. Checked before the score in every swap (fail-closed).
    ISanctionRegistry public sanctionRegistry;
    /// @notice Layer 2 COA-score store. Read at beforeSwap; never written by the hook.
    IComplianceOracle public complianceOracle;
    /// @notice Layer 3 pure decision contract. Hot-path `decide` plus off-chain preview.
    IRiskPolicy public riskPolicy;

    /// @notice True when the router is allowed to act as a subject intermediary.
    mapping(address => bool) public trustedRouters;
    /// @notice Registered multisig accounts and their type for owner-level screening.
    mapping(address => TrustedMultisig) public trustedMultisigs;
    /// @notice Chainlink AggregatorV3 feed registered per token for USD magnitude floors.
    mapping(address => IAggregatorV3) public priceFeeds;
    /// @notice Last good USD round per token. Hot cache under `FX_HOT_TTL` (30m); fallback until `MAX_PRICE_STALENESS` (24h).
    mapping(address => OracleQuote.CachedFx) public lastFx;

    /// @notice Owner-level sanction aggregation policy for multisig wallets.
    MultisigAggregation public multisigAggregation = MultisigAggregation.ALL_CLEAN;

    /// @notice Seconds after which a published score is considered stale (Floor B / Mitigation D).
    /// @dev Default 5 minutes. The off-chain keeper ticks every 3 minutes (shorter than this)
    ///      so a healthy API never looks stale even when the COA is not re-run. If the agent
    ///      never published (`updatedAt == 0`), Floor A applies instead of B.
    uint256 public stalenessThreshold;
    /// @notice Default `stalenessThreshold` applied when the constructor receives 0 (5 minutes).
    /// @dev Sized so a 3-minute keeper heartbeat stays inside the window (whitepaper §8.4).
    uint256 public constant DEFAULT_STALENESS = 5 minutes;
    /// @notice Hard upper bound on `stalenessThreshold`. Exceeding it reverts.
    uint256 public constant MAX_STALENESS = 24 hours;

    /// @notice Minimum seconds between automatic Mitigation D baseline refreshes per wallet/token.
    uint64 public minBaselineInterval = 1 hours;
    /// @notice Rolling window for operation-count and USD accumulators (Floors B / C).
    uint64 public activityWindow;
    /// @notice Rolling window for the daily USD aggregation check (Floor C daily gate).
    uint64 public dailyWindow;
    /// @notice Max age (seconds) for a live Chainlink round before it is treated as stale.
    uint256 public priceStalenessThreshold;
    /// @notice Inflow share above which Mitigation D classifies a balance increase as significant (bps).
    uint256 public inflowThresholdBps;
    /// @notice USD threshold (8-decimal) below which an unscored swap pays the proportional fee.
    uint256 public unscoredFeeThreshold;
    /// @notice USD threshold (8-decimal) at or above which an unscored swap is reverted.
    uint256 public unscoredRevertThreshold;
    /// @notice Pool-impact bps above which extra floor hardening applies (Floors A/B extra).
    uint256 public poolImpactThresholdBps;
    /// @notice Proportional floor fee for medium-risk conditions (bps). Governor-tunable.
    uint24 public proportionalFeeBps;
    /// @notice Punitive floor fee for high-risk or near-revert conditions (bps). Governor-tunable.
    uint24 public punitiveFeeBps;

    /// @notice Default `activityWindow` applied when the constructor receives 0.
    uint64 public constant DEFAULT_ACTIVITY_WINDOW = 1 hours;
    /// @notice Default `dailyWindow` applied at construction.
    uint64 public constant DEFAULT_DAILY_WINDOW = 24 hours;
    /// @notice Minimum allowed `activityWindow` (60 seconds).
    uint64 public constant MIN_ACTIVITY_WINDOW = 60;
    /// @notice Maximum allowed `activityWindow`.
    uint64 public constant MAX_ACTIVITY_WINDOW = 7 days;
    /// @notice Minimum allowed `dailyWindow`.
    uint64 public constant MIN_DAILY_WINDOW = 1 hours;
    /// @notice Maximum allowed `dailyWindow`.
    uint64 public constant MAX_DAILY_WINDOW = 7 days;
    /// @notice Default `unscoredFeeThreshold` in 8-decimal USD ($1 000).
    uint256 public constant DEFAULT_USD_FEE_THRESHOLD = 1_000e8;
    /// @notice Default `unscoredRevertThreshold` in 8-decimal USD ($15 000).
    uint256 public constant DEFAULT_USD_REVERT_THRESHOLD = 15_000e8;
    /// @notice FATF wire-transfer threshold: `unscoredFeeThreshold` cannot go below this ($1 000).
    uint256 public constant MIN_UNSCORED_FEE_THRESHOLD = 1_000e8;
    /// @notice Default `priceStalenessThreshold` in seconds (1 hour).
    uint256 public constant DEFAULT_PRICE_STALENESS = 3600;
    /// @notice Hard cap on `priceStalenessThreshold`; also the max age for the `lastFx` fallback cache.
    uint256 public constant MAX_PRICE_STALENESS = 24 hours;
    /// @notice Age below which `lastFx` is used directly without calling Chainlink (30 minutes).
    uint256 public constant FX_HOT_TTL = 30 minutes;
    /// @notice Default pool-impact threshold: 20% of the active-tick virtual reserve.
    uint256 public constant DEFAULT_POOL_IMPACT_THRESHOLD_BPS = 2000;
    /// @notice Deploy-time latency fee — matches `FeeBps.LATENCY`. Stored for ABI discoverability.
    uint24 public constant LATENCY_FEE_BPS = FeeBps.LATENCY;

    /// @notice Parameter key used in `PolicyParam*` events for the unscored fee threshold.
    string public constant PARAM_UNSCORED_FEE_THRESHOLD = "unscoredFeeThreshold";
    /// @notice Parameter key used in `PolicyParam*` events for the unscored revert threshold.
    string public constant PARAM_UNSCORED_REVERT_THRESHOLD = "unscoredRevertThreshold";
    /// @notice Parameter key used in `PolicyParam*` events for the pool-impact threshold.
    string public constant PARAM_POOL_IMPACT_THRESHOLD_BPS = "poolImpactThresholdBps";
    /// @notice Parameter key used in `PolicyParam*` events for the proportional floor fee.
    string public constant PARAM_PROPORTIONAL_FEE_BPS = "proportionalFeeBps";
    /// @notice Parameter key used in `PolicyParam*` events for the punitive floor fee.
    string public constant PARAM_PUNITIVE_FEE_BPS = "punitiveFeeBps";

    /// @dev In-flight proposal for a two-step policy parameter change.
    ///      `a` / `b` are the proposed values; `prevA` / `prevB` are the current ones.
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

    /// @notice `unscoredFeeThreshold` would fall below the FATF wire-transfer minimum.
    error UnscoredFeeThresholdBelowFatfMinimum(uint256 feeThreshold, uint256 minimum);
    /// @notice `unscoredRevertThreshold` must be strictly greater than `unscoredFeeThreshold`.
    error UnscoredRevertMustExceedFee(uint256 feeThreshold, uint256 revertThreshold);
    /// @notice `punitiveFeeBps` must be strictly greater than `proportionalFeeBps`.
    error PunitiveFeeMustExceedProportional(uint24 proportionalFeeBps, uint24 punitiveFeeBps);
    /// @notice `apply*` called but no matching pending proposal exists for this parameter.
    error NoPendingPolicyParam(string name);
    /// @notice Values supplied to `apply*` do not match the pending proposal.
    error PendingPolicyParamMismatch(string name);
    /// @notice `priceStalenessThreshold` is zero or exceeds `MAX_PRICE_STALENESS`.
    error PriceStalenessThresholdInvalid();
    /// @notice `activityWindow` is outside [`MIN_ACTIVITY_WINDOW`, `MAX_ACTIVITY_WINDOW`].
    error ActivityWindowInvalid();
    /// @notice `dailyWindow` is outside [`MIN_DAILY_WINDOW`, `MAX_DAILY_WINDOW`].
    error DailyWindowInvalid();
    /// @notice `inflowThresholdBps` is outside [`MIN_INFLOW_THRESHOLD`, `MAX_INFLOW_THRESHOLD`].
    error InflowThresholdOutOfRange();
    /// @notice `stalenessThreshold` is zero.
    error StalenessThresholdTooLow();
    /// @notice `stalenessThreshold` exceeds `MAX_STALENESS`.
    error StalenessThresholdTooHigh();
    /// @notice `minBaselineInterval` cannot be set to zero.
    error BaselineIntervalZero();
    /// @notice Router not trusted or subject resolution returned `address(0)`.
    error MissingSwapSubject();

    /// @notice Emitted when `minBaselineInterval` changes.
    event MinBaselineIntervalUpdated(uint64 previous, uint64 current);
    /// @notice Emitted when a multisig's trusted status or type changes.
    event TrustedMultisigUpdated(address indexed account, MultisigType kind, bool trusted);
    /// @notice Emitted when the multisig owner-sanction aggregation policy changes.
    event MultisigAggregationUpdated(MultisigAggregation previous, MultisigAggregation current);
    /// @notice Emitted when `stalenessThreshold` changes.
    event StalenessThresholdUpdated(uint256 previous, uint256 current);
    /// @notice Emitted when `inflowThresholdBps` changes.
    event InflowThresholdUpdated(uint256 previous, uint256 current);
    /// @notice Emitted by the compliance officer when a two-step policy parameter change is proposed.
    event PolicyParamProposed(string name, uint256 previousValue, uint256 newValue, address indexed actor);
    /// @notice Emitted immediately after `PolicyParamProposed` with the role-delay-adjusted ready timestamp.
    event PolicyParamScheduled(
        string name, uint256 previousValue, uint256 newValue, address indexed actor, uint48 readyAt
    );
    /// @notice Emitted when the governor confirms a pending policy parameter change.
    event PolicyParamConfirmed(string name, uint256 previousValue, uint256 newValue, address indexed actor);
    /// @notice Emitted when `poolImpactThresholdBps` changes.
    event PoolImpactThresholdUpdated(uint256 previous, uint256 current);
    /// @notice Emitted when both unscored thresholds change atomically.
    event UnscoredThresholdsUpdated(
        uint256 previousFeeThreshold, uint256 previousRevertThreshold, uint256 feeThreshold, uint256 revertThreshold
    );
    /// @notice Emitted when a Chainlink price feed is registered or replaced for a token.
    event PriceFeedUpdated(address indexed token, address previousFeed, address feed);
    /// @notice Emitted when the FX fallback cache is used instead of a live Chainlink round.
    /// @param token      Token whose price was resolved from cache.
    /// @param price      Cached price (raw Chainlink units).
    /// @param quotedAt   Timestamp of the cached round.
    /// @param fromCache  Always true in this event.
    /// @param stale      True when the cache age exceeds `priceStalenessThreshold`.
    event PriceFallbackUsed(address indexed token, uint256 price, uint64 quotedAt, bool fromCache, bool stale);
    /// @notice Emitted when `priceStalenessThreshold` changes.
    event PriceStalenessThresholdUpdated(uint256 previous, uint256 current);
    /// @notice Emitted when `activityWindow` changes.
    event ActivityWindowUpdated(uint64 previous, uint64 current);
    /// @notice Emitted when `dailyWindow` changes.
    event DailyWindowUpdated(uint64 previousWindow, uint64 dailyWindow);
    /// @notice Emitted when a router's trusted status changes.
    event TrustedRouterUpdated(address indexed router, bool trusted);

    /// @param accessManager_ OpenZeppelin AccessManager governing role assignments.
    constructor(address accessManager_) AccessManaged(accessManager_) {}

    /// @dev Called once by AmlHook.initialize. Sets compliance dependencies and default thresholds.
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

    /// @notice Update the score staleness threshold. Must be in (0, `MAX_STALENESS`].
    function setStalenessThreshold(uint256 stalenessThreshold_) external restricted {
        if (stalenessThreshold_ == 0) revert StalenessThresholdTooLow();
        if (stalenessThreshold_ > MAX_STALENESS) revert StalenessThresholdTooHigh();
        emit StalenessThresholdUpdated(stalenessThreshold, stalenessThreshold_);
        stalenessThreshold = stalenessThreshold_;
    }

    /// @notice Update the minimum time between automatic Mitigation D baseline refreshes.
    /// @param minBaselineInterval_ New interval in seconds; must be non-zero.
    function setMinBaselineInterval(uint64 minBaselineInterval_) external restricted {
        if (minBaselineInterval_ == 0) revert BaselineIntervalZero();
        emit MinBaselineIntervalUpdated(minBaselineInterval, minBaselineInterval_);
        minBaselineInterval = minBaselineInterval_;
    }

    /// @notice Pause the hook — all beforeSwap calls will revert while paused.
    function pause() external restricted {
        _pause();
    }

    /// @notice Resume normal operation after a pause.
    function unpause() external restricted {
        _unpause();
    }

    /// @notice Update the Mitigation D inflow threshold.
    /// @param inflowThresholdBps_ New threshold in bps; must be in [`MIN_INFLOW_THRESHOLD`, `MAX_INFLOW_THRESHOLD`].
    function setInflowThresholdBps(uint256 inflowThresholdBps_) external restricted {
        if (inflowThresholdBps_ < FeeBps.MIN_INFLOW_THRESHOLD || inflowThresholdBps_ > FeeBps.MAX_INFLOW_THRESHOLD) {
            revert InflowThresholdOutOfRange();
        }
        emit InflowThresholdUpdated(inflowThresholdBps, inflowThresholdBps_);
        inflowThresholdBps = inflowThresholdBps_;
    }

    /// @notice Step 1 (compliance officer): propose a new `poolImpactThresholdBps`.
    ///         Step 2 is `applyPoolImpactThresholdBps` (governor).
    function proposePoolImpactThresholdBps(uint256 poolImpactThresholdBps_) external {
        _requireComplianceOfficer();
        _propose(_ID_IMPACT, poolImpactThresholdBps_, 0, poolImpactThresholdBps, 0);
        _emitProposed(PARAM_POOL_IMPACT_THRESHOLD_BPS, poolImpactThresholdBps, poolImpactThresholdBps_);
        _emitScheduled(PARAM_POOL_IMPACT_THRESHOLD_BPS, poolImpactThresholdBps, poolImpactThresholdBps_);
    }

    /// @notice Step 2 (governor): confirm and apply the pending `poolImpactThresholdBps` proposal.
    ///         Reverts if no proposal exists or the supplied value mismatches.
    function applyPoolImpactThresholdBps(uint256 poolImpactThresholdBps_) external restricted {
        Pending memory p = _consume(_ID_IMPACT, poolImpactThresholdBps_, 0, PARAM_POOL_IMPACT_THRESHOLD_BPS);
        _emitConfirmed(PARAM_POOL_IMPACT_THRESHOLD_BPS, p.prevA, poolImpactThresholdBps_, p.proposer);
        emit PoolImpactThresholdUpdated(p.prevA, poolImpactThresholdBps_);
        poolImpactThresholdBps = poolImpactThresholdBps_;
    }

    /// @notice Step 1 (compliance officer): propose new unscored fee and revert thresholds atomically.
    ///         Validates FATF minimum and ordering invariant before storing the proposal.
    function proposeUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) external {
        _requireComplianceOfficer();
        _validateUnscoredThresholds(feeThreshold, revertThreshold);
        _propose(_ID_UNSCORED, feeThreshold, revertThreshold, unscoredFeeThreshold, unscoredRevertThreshold);
        _emitProposed(PARAM_UNSCORED_FEE_THRESHOLD, unscoredFeeThreshold, feeThreshold);
        _emitProposed(PARAM_UNSCORED_REVERT_THRESHOLD, unscoredRevertThreshold, revertThreshold);
        _emitScheduled(PARAM_UNSCORED_FEE_THRESHOLD, unscoredFeeThreshold, feeThreshold);
        _emitScheduled(PARAM_UNSCORED_REVERT_THRESHOLD, unscoredRevertThreshold, revertThreshold);
    }

    /// @notice Step 2 (governor): confirm and apply the pending unscored threshold proposal.
    ///         Re-validates invariants to guard against storage drift between propose and apply.
    function applyUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) external restricted {
        Pending memory p = _consume(_ID_UNSCORED, feeThreshold, revertThreshold, PARAM_UNSCORED_FEE_THRESHOLD);
        _validateUnscoredThresholds(feeThreshold, revertThreshold);
        _emitConfirmed(PARAM_UNSCORED_FEE_THRESHOLD, p.prevA, feeThreshold, p.proposer);
        _emitConfirmed(PARAM_UNSCORED_REVERT_THRESHOLD, p.prevB, revertThreshold, p.proposer);
        emit UnscoredThresholdsUpdated(p.prevA, p.prevB, feeThreshold, revertThreshold);
        unscoredFeeThreshold = feeThreshold;
        unscoredRevertThreshold = revertThreshold;
    }

    /// @notice Step 1 (compliance officer): propose new proportional and punitive floor fees.
    ///         Punitive must strictly exceed proportional.
    function proposeFloorFees(uint24 proportionalFeeBps_, uint24 punitiveFeeBps_) external {
        _requireComplianceOfficer();
        _validateFloorFees(proportionalFeeBps_, punitiveFeeBps_);
        _propose(_ID_FEES, proportionalFeeBps_, punitiveFeeBps_, proportionalFeeBps, punitiveFeeBps);
        _emitProposed(PARAM_PROPORTIONAL_FEE_BPS, proportionalFeeBps, proportionalFeeBps_);
        _emitProposed(PARAM_PUNITIVE_FEE_BPS, punitiveFeeBps, punitiveFeeBps_);
        _emitScheduled(PARAM_PROPORTIONAL_FEE_BPS, proportionalFeeBps, proportionalFeeBps_);
        _emitScheduled(PARAM_PUNITIVE_FEE_BPS, punitiveFeeBps, punitiveFeeBps_);
    }

    /// @notice Step 2 (governor): confirm and apply the pending floor fee proposal.
    function applyFloorFees(uint24 proportionalFeeBps_, uint24 punitiveFeeBps_) external restricted {
        Pending memory p = _consume(_ID_FEES, proportionalFeeBps_, punitiveFeeBps_, PARAM_PROPORTIONAL_FEE_BPS);
        _validateFloorFees(proportionalFeeBps_, punitiveFeeBps_);
        _emitConfirmed(PARAM_PROPORTIONAL_FEE_BPS, p.prevA, proportionalFeeBps_, p.proposer);
        _emitConfirmed(PARAM_PUNITIVE_FEE_BPS, p.prevB, punitiveFeeBps_, p.proposer);
        proportionalFeeBps = proportionalFeeBps_;
        punitiveFeeBps = punitiveFeeBps_;
    }

    /// @notice Register or replace the Chainlink AggregatorV3 feed for `token`.
    ///         Pass `address(0)` as `feed` to disable magnitude floors for that token.
    function setPriceFeed(address token, address feed) external restricted {
        address previous = address(priceFeeds[token]);
        priceFeeds[token] = IAggregatorV3(feed);
        emit PriceFeedUpdated(token, previous, feed);
    }

    /// @notice Update the rolling activity window. Must be in [`MIN_ACTIVITY_WINDOW`, `MAX_ACTIVITY_WINDOW`].
    function setActivityWindow(uint64 activityWindow_) external restricted {
        _applyActivityWindow(activityWindow_);
    }

    /// @notice Update the daily USD aggregation window. Must be in [`MIN_DAILY_WINDOW`, `MAX_DAILY_WINDOW`].
    function setDailyWindow(uint64 dailyWindow_) external restricted {
        if (dailyWindow_ < MIN_DAILY_WINDOW || dailyWindow_ > MAX_DAILY_WINDOW) revert DailyWindowInvalid();
        emit DailyWindowUpdated(dailyWindow, dailyWindow_);
        dailyWindow = dailyWindow_;
    }

    /// @notice Update the max age for a live Chainlink round before it is treated as stale.
    ///         Must be in (0, `MAX_PRICE_STALENESS`].
    function setPriceStalenessThreshold(uint256 priceStalenessThreshold_) external restricted {
        if (priceStalenessThreshold_ == 0 || priceStalenessThreshold_ > MAX_PRICE_STALENESS) {
            revert PriceStalenessThresholdInvalid();
        }
        emit PriceStalenessThresholdUpdated(priceStalenessThreshold, priceStalenessThreshold_);
        priceStalenessThreshold = priceStalenessThreshold_;
    }

    /// @notice Grant or revoke a router's trusted status for subject resolution.
    function setTrustedRouter(address router, bool trusted) external restricted {
        trustedRouters[router] = trusted;
        emit TrustedRouterUpdated(router, trusted);
    }

    /// @notice Register a multisig account for owner-level sanction screening.
    /// @dev `kind` must not be NONE when `trusted = true`. Revoking sets kind to NONE.
    function setTrustedMultisig(address account, MultisigType kind, bool trusted) external restricted {
        if (account == address(0)) revert MissingSwapSubject();
        if (trusted && kind == MultisigType.NONE) revert MissingSwapSubject();
        trustedMultisigs[account] = TrustedMultisig({trusted: trusted, kind: trusted ? kind : MultisigType.NONE});
        emit TrustedMultisigUpdated(account, kind, trusted);
    }

    /// @notice Change the aggregation rule applied when screening multisig owners.
    ///         `ALL_CLEAN` reverts if any owner is sanctioned; `ANY_CLEAN` reverts only if all are.
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
    }

    function _emitScheduled(string memory name, uint256 previousValue, uint256 newValue) private {
        (, uint32 delay) = IAccessManager(authority()).hasRole(Roles._COMPLIANCE_OFFICER, msg.sender);
        emit PolicyParamScheduled(name, previousValue, newValue, msg.sender, uint48(block.timestamp) + delay);
    }

    function _emitConfirmed(string memory name, uint256 previousValue, uint256 newValue, address actor) private {
        emit PolicyParamConfirmed(name, previousValue, newValue, actor);
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
