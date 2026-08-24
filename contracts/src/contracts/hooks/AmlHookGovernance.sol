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

/// @title Governance state and setters for the AML hook
/// @notice Holds all configuration state and the two-step governance functions.
///         Does NOT contain swap evaluation or activity tracking logic.
/// @dev Inheritance root of the linear chain:
///      AmlHookGovernance → AmlHookActivity → AmlHookLogic → AmlHook
abstract contract AmlHookGovernance is AccessManaged, Pausable {
    ISanctionRegistry public immutable sanctionRegistry;
    IComplianceOracle public immutable complianceOracle;
    IRiskPolicy public immutable riskPolicy;

    /// @notice Routers allowed to report the end-user via `IMsgSender.msgSender()`.
    /// @dev Why: PoolManager's `sender` is usually the router, not the user. Scoring
    ///      the router would either bypass control (clean router) or block everyone
    ///      (contaminated router). Trusted routers implement `msgSender()` so we score
    ///      the real economic actor (§3.5).
    mapping(address => bool) public trustedRouters;

    /// @notice Max age of an oracle score before it is treated as stale (seconds).
    /// @dev Floor B (whitepaper §8.4). Default 5 minutes so a retail keeper that writes
    ///      every 3–5 minutes does not look stale between honest writes. Busy pools can
    ///      tighten to ~120s via `setStalenessThreshold`. Do not set below ~120s in
    ///      production: validators can nudge `block.timestamp`. Bounds `[1, MAX_STALENESS]`.
    uint256 public stalenessThreshold;
    uint256 public constant DEFAULT_STALENESS = 5 minutes;
    uint256 public constant MAX_STALENESS = 24 hours;

    /// @notice Minimum seconds between `lastKnownBalance` baseline writes (H-02).
    uint64 public minBaselineInterval = 1 hours;

    /// @notice How owner-level L1 sanctions are aggregated for a trusted multisig (C-03).
    /// @dev Applies to `isSanctioned` only. Owner behavioral scores are not aggregated on-chain.
    enum MultisigAggregation {
        ALL_CLEAN,
        ANY_CLEAN
    }

    /// @notice Recognised smart-account types for `_resolveWallet`.
    enum MultisigType {
        NONE,
        GNOSIS_SAFE
    }

    struct TrustedMultisig {
        bool trusted;
        MultisigType kind;
    }

    mapping(address => TrustedMultisig) public trustedMultisigs;
    MultisigAggregation public multisigAggregation = MultisigAggregation.ALL_CLEAN;

    /// @notice Rolling 1-hour window for Floor B (ops + USD of this swap plus the hour).
    /// @dev `_HOOK_GOVERNOR` retunes via `setActivityWindow` (default 1 hour; bounds `[MIN, MAX]`).
    uint64 public activityWindow;

    /// @notice Ops inside the 1-hour window. Used to arm Floor B (`operationCount > 0`).
    /// @dev Kept on the governor setter for ABI compatibility. Floor C no longer uses an op cap.
    uint32 public maxOpsInWindow;

    /// @notice Rolling 24-hour USD window for Floor C (BSA CTR-style daily aggregation).
    /// @dev While prior 24h USD is 0 or the sum stays under `unscoredRevertThreshold`, C
    ///      does not intervene. The later swap that crosses that live high floor REVERTs.
    uint64 public dailyWindow;

    uint64 public constant DEFAULT_ACTIVITY_WINDOW = 1 hours;
    uint32 public constant DEFAULT_MAX_OPS_IN_WINDOW = 3;
    uint64 public constant DEFAULT_DAILY_WINDOW = 24 hours;
    uint64 public constant MIN_ACTIVITY_WINDOW = 60;
    uint64 public constant MAX_ACTIVITY_WINDOW = 7 days;
    uint64 public constant MIN_DAILY_WINDOW = 1 hours;
    uint64 public constant MAX_DAILY_WINDOW = 7 days;
    uint32 public constant MIN_MAX_OPS_IN_WINDOW = 1;
    uint32 public constant MAX_MAX_OPS_IN_WINDOW = 100;

    /// @notice USD-8 floor below which an unscored swap pays the live proportional fee.
    /// @dev Chainlink 8 decimals (default 1_000e8 = $1,000). FATF 2021 VASP guidance VA
    ///      threshold (note 37). `_COMPLIANCE_OFFICER` may raise it; cannot go below
    ///      `MIN_UNSCORED_FEE_THRESHOLD`. Must stay strictly below `unscoredRevertThreshold`.
    uint256 public unscoredFeeThreshold;

    /// @notice USD-8 high band: never-scored REVERT; published B/D charge the punitive fee.
    /// @dev Default 15_000e8 = $15,000 (FATF Rec. 10 occasional-transaction CDD).
    ///      A REVERTs on this swap alone. B/D charge `punitiveFeeBps` at/above it. C REVERTs
    ///      when prior 24h USD plus this swap crosses it. Must stay strictly above the fee floor.
    uint256 public unscoredRevertThreshold;

    /// @notice Chainlink token/USD feed per specified-currency token (`address(0)` = native ETH).
    /// @dev Governor-attested. Missing or stale feed is fail-closed for magnitude quotes.
    mapping(address => IAggregatorV3) public priceFeeds;

    /// @notice Max age of `latestRoundData.updatedAt` before a feed is treated as stale (seconds).
    /// @dev Distinct from score `stalenessThreshold` / WalletRisk.updatedAt. Default 3600.
    uint256 public priceStalenessThreshold;

    uint256 public constant DEFAULT_USD_FEE_THRESHOLD = 1_000e8;
    uint256 public constant DEFAULT_USD_REVERT_THRESHOLD = 15_000e8;
    /// @notice FATF 2021 VASP guidance note 37 VA threshold. The fee floor cannot go below this.
    uint256 public constant MIN_UNSCORED_FEE_THRESHOLD = 1_000e8;
    uint256 public constant DEFAULT_PRICE_STALENESS = 3600;
    uint256 public constant MAX_PRICE_STALENESS = 24 hours;

    /// @notice Share of the pool's active virtual reserve (bps) that hardens Floors A and B.
    /// @dev Default 2000 = 20%. A: mid → punitive, punitive → REVERT. B: pass → proportional,
    ///      proportional → punitive (ceiling; never REVERT). Compliance-officer retunable. 0 disables.
    uint256 public poolImpactThresholdBps;
    uint256 public constant DEFAULT_POOL_IMPACT_THRESHOLD_BPS = 2000;

    /// @notice Live Floor A/B/D mid-band fee (default `FeeBps.PROPORTIONAL` = 3%).
    /// @dev Must stay strictly below `punitiveFeeBps`. Not capped by `FeeBps.MAX_OVERRIDE`.
    uint24 public proportionalFeeBps;

    /// @notice Live Floor A/B/D high-band fee (default `FeeBps.PUNITIVE` = 8%).
    /// @dev Must stay strictly above `proportionalFeeBps`. Not capped by `FeeBps.MAX_OVERRIDE`.
    uint24 public punitiveFeeBps;

    /// @notice Event `name` for the USD fee floor (same string on propose and confirm).
    string public constant PARAM_UNSCORED_FEE_THRESHOLD = "unscoredFeeThreshold";
    /// @notice Event `name` for the USD revert / high floor.
    string public constant PARAM_UNSCORED_REVERT_THRESHOLD = "unscoredRevertThreshold";
    /// @notice Event `name` for the A/B pool-impact cut.
    string public constant PARAM_POOL_IMPACT_THRESHOLD_BPS = "poolImpactThresholdBps";
    /// @notice Event `name` for the live proportional (mid-band) floor fee.
    string public constant PARAM_PROPORTIONAL_FEE_BPS = "proportionalFeeBps";
    /// @notice Event `name` for the live punitive / latency (high-band) floor fee.
    string public constant PARAM_PUNITIVE_FEE_BPS = "punitiveFeeBps";

    /// @notice Last proposed USD-floor pair awaiting `applyUnscoredThresholds`.
    struct PendingUnscoredThresholds {
        uint256 feeThreshold;
        uint256 revertThreshold;
        uint256 previousFeeThreshold;
        uint256 previousRevertThreshold;
        address proposer;
        bool exists;
    }

    /// @notice Last proposed pool-impact cut awaiting `applyPoolImpactThresholdBps`.
    struct PendingPoolImpact {
        uint256 value;
        uint256 previousValue;
        address proposer;
        bool exists;
    }

    /// @notice Last proposed floor-fee pair awaiting `applyFloorFees`.
    struct PendingFloorFees {
        uint24 proportionalFeeBps;
        uint24 punitiveFeeBps;
        uint24 previousProportionalFeeBps;
        uint24 previousPunitiveFeeBps;
        address proposer;
        bool exists;
    }

    /// @notice Outstanding USD-floor proposal, if any.
    PendingUnscoredThresholds public pendingUnscoredThresholds;
    /// @notice Outstanding pool-impact proposal, if any.
    PendingPoolImpact public pendingPoolImpact;
    /// @notice Outstanding floor-fee proposal, if any.
    PendingFloorFees public pendingFloorFees;

    /// @notice Inbound USD share (bps of current USD-8 bag) that flags a medium-risk increment.
    /// @dev Mitigation D (§3.8) / use-case Wallet D. Default 5000 = 50% of current USD.
    ///      Used for the inflow audit event only. D's fee is the inbound-USD band
    ///      (pass / `proportionalFeeBps` / `punitiveFeeBps`).
    uint256 public inflowThresholdBps;

    /// @notice Default high-band fee constant (8%). Live value is `punitiveFeeBps`.
    /// @dev Kept for ABI compatibility. `FeeBps.MAX_OVERRIDE` does not cap `punitiveFeeBps`.
    uint24 public constant LATENCY_FEE_BPS = FeeBps.LATENCY;

    error UnscoredFeeThresholdBelowFatfMinimum(uint256 feeThreshold, uint256 minimum);
    error UnscoredRevertMustExceedFee(uint256 feeThreshold, uint256 revertThreshold);
    error PunitiveFeeMustExceedProportional(uint24 proportionalFeeBps, uint24 punitiveFeeBps);
    error NoPendingPolicyParam(string name);
    error PendingPolicyParamMismatch(string name);
    error PriceStalenessThresholdInvalid();
    error ActivityWindowInvalid();
    error DailyWindowInvalid();
    error MaxOpsInWindowInvalid();
    error InflowThresholdOutOfRange();
    error StalenessThresholdTooLow();
    error StalenessThresholdTooHigh();
    error BaselineIntervalZero();
    /// @notice Caller is not a trusted router — no end-user can be resolved (fail-closed §3.5).
    error MissingSwapSubject();

    event MinBaselineIntervalUpdated(uint64 previous, uint64 current);
    event TrustedMultisigUpdated(address indexed account, MultisigType kind, bool trusted);
    event MultisigAggregationUpdated(MultisigAggregation previous, MultisigAggregation current);
    event StalenessThresholdUpdated(uint256 previous, uint256 current);
    event InflowThresholdUpdated(uint256 previous, uint256 current);
    /// @notice Compliance officer proposed a policy knob. Live state is unchanged until `apply*`.
    /// @param name Canonical parameter id (`PARAM_*` constants).
    /// @param previousValue Value currently in storage.
    /// @param newValue Proposed value (not yet live).
    /// @param actor Officer who proposed (`msg.sender`).
    event PolicyParamProposed(string name, uint256 previousValue, uint256 newValue, address indexed actor);
    /// @notice Schedule announcement for a proposal. AccessManager.schedule cannot carry param metadata.
    /// @dev Fired from `propose*` (the hook-owned schedule moment) with
    ///      `readyAt = block.timestamp + officer grant delay`. Confirm still emits
    ///      `PolicyParamConfirmed` when `apply*` executes.
    event PolicyParamScheduled(
        string name,
        uint256 previousValue,
        uint256 newValue,
        address indexed actor,
        uint48 readyAt
    );
    /// @notice Compliance officer confirmed a matching proposal after the AccessManager delay.
    /// @param name Canonical parameter id (`PARAM_*` constants).
    /// @param previousValue Value before this confirmation.
    /// @param newValue Value now stored.
    /// @param actor Officer who proposed (not AccessManager, which is `msg.sender` on execute).
    event PolicyParamConfirmed(string name, uint256 previousValue, uint256 newValue, address indexed actor);
    event PoolImpactThresholdUpdated(uint256 previous, uint256 current);
    event UnscoredThresholdsUpdated(
        uint256 previousFeeThreshold,
        uint256 previousRevertThreshold,
        uint256 feeThreshold,
        uint256 revertThreshold
    );
    event PriceFeedUpdated(address indexed token, address previousFeed, address feed);
    event PriceStalenessThresholdUpdated(uint256 previous, uint256 current);
    event ActivityWindowUpdated(
        uint64 previousWindow, uint32 previousMaxOps, uint64 activityWindow, uint32 maxOpsInWindow
    );
    event DailyWindowUpdated(uint64 previousWindow, uint64 dailyWindow);
    event TrustedRouterUpdated(address indexed router, bool trusted);

    /// @notice Wire L1/L2/L3 and seed operational + policy defaults.
    /// @dev USD floors default to $1,000 / $15,000; floor fees to 3% / 8%; pool-impact to 20%.
    ///      After deploy, `_COMPLIANCE_OFFICER` retunes those via propose / apply.
    /// @param accessManager_ Shared AccessManager (governor + compliance officer).
    /// @param sanctionRegistry_ Layer 1 list.
    /// @param complianceOracle_ Layer 2 score store.
    /// @param riskPolicy_ Layer 3 pure mapping.
    /// @param stalenessThreshold_ Floor B freshness; 0 → `DEFAULT_STALENESS`.
    /// @param activityWindow_ Floor B window; 0 → `DEFAULT_ACTIVITY_WINDOW`.
    /// @param maxOpsInWindow_ Unused op-cap storage; 0 → `DEFAULT_MAX_OPS_IN_WINDOW`.
    constructor(
        address accessManager_,
        ISanctionRegistry sanctionRegistry_,
        IComplianceOracle complianceOracle_,
        IRiskPolicy riskPolicy_,
        uint256 stalenessThreshold_,
        uint64 activityWindow_,
        uint32 maxOpsInWindow_
    ) AccessManaged(accessManager_) {
        sanctionRegistry = sanctionRegistry_;
        complianceOracle = complianceOracle_;
        riskPolicy = riskPolicy_;
        // Zero means "use the published default" (5 minutes). Not "stale immediately".
        if (stalenessThreshold_ == 0) {
            stalenessThreshold = DEFAULT_STALENESS;
        } else {
            if (stalenessThreshold_ > MAX_STALENESS) revert StalenessThresholdTooHigh();
            stalenessThreshold = stalenessThreshold_;
        }
        _applyActivityWindow(
            activityWindow_ == 0 ? DEFAULT_ACTIVITY_WINDOW : activityWindow_,
            maxOpsInWindow_ == 0 ? DEFAULT_MAX_OPS_IN_WINDOW : maxOpsInWindow_
        );
        dailyWindow = DEFAULT_DAILY_WINDOW;
        emit DailyWindowUpdated(0, dailyWindow);
        inflowThresholdBps = 5000; // 50% — Wallet D / Mitigation D default
        // USD-8 floors (Chainlink decimals). Compliance officer retunes via propose/apply.
        unscoredFeeThreshold = DEFAULT_USD_FEE_THRESHOLD;
        unscoredRevertThreshold = DEFAULT_USD_REVERT_THRESHOLD;
        proportionalFeeBps = FeeBps.PROPORTIONAL;
        punitiveFeeBps = FeeBps.PUNITIVE;
        priceStalenessThreshold = DEFAULT_PRICE_STALENESS;
        poolImpactThresholdBps = DEFAULT_POOL_IMPACT_THRESHOLD_BPS;
        emit StalenessThresholdUpdated(0, stalenessThreshold);
        emit PoolImpactThresholdUpdated(0, poolImpactThresholdBps);
        emit InflowThresholdUpdated(0, inflowThresholdBps);
        emit UnscoredThresholdsUpdated(0, 0, unscoredFeeThreshold, unscoredRevertThreshold);
        emit PriceStalenessThresholdUpdated(0, priceStalenessThreshold);
    }

    /// @notice Hook governor retunes Floor B (whitepaper §8.4).
    /// @dev Pair this with the keeper write cadence. Retail 3–5 minutes → keep the 5-minute
    ///      default. Institutional 30–60s writes → 120s is fine. Keepers must not retune this.
    function setStalenessThreshold(uint256 stalenessThreshold_) external restricted {
        if (stalenessThreshold_ == 0) revert StalenessThresholdTooLow();
        if (stalenessThreshold_ > MAX_STALENESS) revert StalenessThresholdTooHigh();
        emit StalenessThresholdUpdated(stalenessThreshold, stalenessThreshold_);
        stalenessThreshold = stalenessThreshold_;
    }

    /// @notice Governor retunes the H-02 baseline write cooldown.
    function setMinBaselineInterval(uint64 minBaselineInterval_) external restricted {
        if (minBaselineInterval_ == 0) revert BaselineIntervalZero();
        emit MinBaselineIntervalUpdated(minBaselineInterval, minBaselineInterval_);
        minBaselineInterval = minBaselineInterval_;
    }

    /// @notice Hook governor pauses all swap evaluation (emergency stop).
    function pause() external restricted {
        _pause();
    }

    /// @notice Hook governor resumes swap evaluation after an emergency pause.
    function unpause() external restricted {
        _unpause();
    }

    /// @notice Hook governor retunes Mitigation D inflow threshold in bps of current USD bag (§3.8).
    /// @dev Floor `FeeBps.MIN_INFLOW_THRESHOLD` (1%) so a zero threshold cannot elevate every dust delta.
    function setInflowThresholdBps(uint256 inflowThresholdBps_) external restricted {
        if (
            inflowThresholdBps_ < FeeBps.MIN_INFLOW_THRESHOLD
                || inflowThresholdBps_ > FeeBps.MAX_INFLOW_THRESHOLD
        ) {
            revert InflowThresholdOutOfRange();
        }
        emit InflowThresholdUpdated(inflowThresholdBps, inflowThresholdBps_);
        inflowThresholdBps = inflowThresholdBps_;
    }

    /// @notice Propose Floors A/B pool-drain cut (bps of active virtual reserve).
    /// @dev `_COMPLIANCE_OFFICER` only, immediate (not `restricted`). No numeric range.
    ///      `0` disables the extra. Does not change live state. Emits `PolicyParamProposed`.
    /// @param poolImpactThresholdBps_ Proposed cut. Confirmed later via `applyPoolImpactThresholdBps`.
    function proposePoolImpactThresholdBps(uint256 poolImpactThresholdBps_) external {
        _requireComplianceOfficer();
        pendingPoolImpact = PendingPoolImpact({
            value: poolImpactThresholdBps_,
            previousValue: poolImpactThresholdBps,
            proposer: msg.sender,
            exists: true
        });
        emit PolicyParamProposed(
            PARAM_POOL_IMPACT_THRESHOLD_BPS, poolImpactThresholdBps, poolImpactThresholdBps_, msg.sender
        );
        _emitPolicyScheduled(
            PARAM_POOL_IMPACT_THRESHOLD_BPS, poolImpactThresholdBps, poolImpactThresholdBps_
        );
    }

    /// @notice Confirm a matching pool-impact proposal after the AccessManager grant delay.
    /// @dev `restricted` to `_COMPLIANCE_OFFICER` (48h delay in Deploy). Calldata must
    ///      equal the stored proposal. Emits `PolicyParamConfirmed` with the proposer as actor.
    /// @param poolImpactThresholdBps_ Must match `pendingPoolImpact.value`.
    function applyPoolImpactThresholdBps(uint256 poolImpactThresholdBps_) external restricted {
        PendingPoolImpact memory pending = pendingPoolImpact;
        if (!pending.exists) revert NoPendingPolicyParam(PARAM_POOL_IMPACT_THRESHOLD_BPS);
        if (pending.value != poolImpactThresholdBps_) {
            revert PendingPolicyParamMismatch(PARAM_POOL_IMPACT_THRESHOLD_BPS);
        }
        emit PolicyParamConfirmed(
            PARAM_POOL_IMPACT_THRESHOLD_BPS, pending.previousValue, poolImpactThresholdBps_, pending.proposer
        );
        emit PoolImpactThresholdUpdated(pending.previousValue, poolImpactThresholdBps_);
        poolImpactThresholdBps = poolImpactThresholdBps_;
        delete pendingPoolImpact;
    }

    /// @notice Propose never-scored fee / revert floors in USD-8 (Chainlink decimals).
    /// @dev `_COMPLIANCE_OFFICER` only, immediate. `feeThreshold` ≥ FATF VA $1,000;
    ///      `revertThreshold` must be strictly greater. No other min/max. Emits one
    ///      `PolicyParamProposed` per parameter. Live state is unchanged until apply.
    /// @param feeThreshold Proposed `unscoredFeeThreshold`.
    /// @param revertThreshold Proposed `unscoredRevertThreshold`.
    function proposeUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) external {
        _requireComplianceOfficer();
        _validateUnscoredThresholds(feeThreshold, revertThreshold);
        pendingUnscoredThresholds = PendingUnscoredThresholds({
            feeThreshold: feeThreshold,
            revertThreshold: revertThreshold,
            previousFeeThreshold: unscoredFeeThreshold,
            previousRevertThreshold: unscoredRevertThreshold,
            proposer: msg.sender,
            exists: true
        });
        emit PolicyParamProposed(PARAM_UNSCORED_FEE_THRESHOLD, unscoredFeeThreshold, feeThreshold, msg.sender);
        emit PolicyParamProposed(
            PARAM_UNSCORED_REVERT_THRESHOLD, unscoredRevertThreshold, revertThreshold, msg.sender
        );
        _emitPolicyScheduled(PARAM_UNSCORED_FEE_THRESHOLD, unscoredFeeThreshold, feeThreshold);
        _emitPolicyScheduled(PARAM_UNSCORED_REVERT_THRESHOLD, unscoredRevertThreshold, revertThreshold);
    }

    /// @notice Confirm a matching USD-floor proposal after the AccessManager grant delay.
    /// @dev `restricted` to `_COMPLIANCE_OFFICER`. Both args must match the stored pair.
    ///      Re-validates the FATF floor and the pair-ordering rule. Emits `PolicyParamConfirmed`
    ///      per parameter with the proposer as actor.
    /// @param feeThreshold Must match `pendingUnscoredThresholds.feeThreshold`.
    /// @param revertThreshold Must match `pendingUnscoredThresholds.revertThreshold`.
    function applyUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) external restricted {
        PendingUnscoredThresholds memory pending = pendingUnscoredThresholds;
        if (!pending.exists) revert NoPendingPolicyParam(PARAM_UNSCORED_FEE_THRESHOLD);
        if (pending.feeThreshold != feeThreshold || pending.revertThreshold != revertThreshold) {
            revert PendingPolicyParamMismatch(PARAM_UNSCORED_FEE_THRESHOLD);
        }
        _validateUnscoredThresholds(feeThreshold, revertThreshold);
        emit PolicyParamConfirmed(
            PARAM_UNSCORED_FEE_THRESHOLD, pending.previousFeeThreshold, feeThreshold, pending.proposer
        );
        emit PolicyParamConfirmed(
            PARAM_UNSCORED_REVERT_THRESHOLD, pending.previousRevertThreshold, revertThreshold, pending.proposer
        );
        emit UnscoredThresholdsUpdated(
            pending.previousFeeThreshold, pending.previousRevertThreshold, feeThreshold, revertThreshold
        );
        unscoredFeeThreshold = feeThreshold;
        unscoredRevertThreshold = revertThreshold;
        delete pendingUnscoredThresholds;
    }

    /// @notice Propose live Floor A/B/D mid / high fees (basis points).
    /// @dev `_COMPLIANCE_OFFICER` only, immediate. Punitive must be strictly greater than
    ///      proportional. No floor on proportional, no cap on punitive (`MAX_OVERRIDE` does
    ///      not apply). Emits one `PolicyParamProposed` per fee.
    /// @param proportionalFeeBps_ Proposed mid-band fee (may be 0).
    /// @param punitiveFeeBps_ Proposed high-band / latency fee.
    function proposeFloorFees(uint24 proportionalFeeBps_, uint24 punitiveFeeBps_) external {
        _requireComplianceOfficer();
        _validateFloorFees(proportionalFeeBps_, punitiveFeeBps_);
        pendingFloorFees = PendingFloorFees({
            proportionalFeeBps: proportionalFeeBps_,
            punitiveFeeBps: punitiveFeeBps_,
            previousProportionalFeeBps: proportionalFeeBps,
            previousPunitiveFeeBps: punitiveFeeBps,
            proposer: msg.sender,
            exists: true
        });
        emit PolicyParamProposed(PARAM_PROPORTIONAL_FEE_BPS, proportionalFeeBps, proportionalFeeBps_, msg.sender);
        emit PolicyParamProposed(PARAM_PUNITIVE_FEE_BPS, punitiveFeeBps, punitiveFeeBps_, msg.sender);
        _emitPolicyScheduled(PARAM_PROPORTIONAL_FEE_BPS, proportionalFeeBps, proportionalFeeBps_);
        _emitPolicyScheduled(PARAM_PUNITIVE_FEE_BPS, punitiveFeeBps, punitiveFeeBps_);
    }

    /// @notice Confirm a matching floor-fee proposal after the AccessManager grant delay.
    /// @dev `restricted` to `_COMPLIANCE_OFFICER`. Both args must match the stored pair.
    ///      Re-validates punitive > proportional. Emits `PolicyParamConfirmed` per fee.
    /// @param proportionalFeeBps_ Must match `pendingFloorFees.proportionalFeeBps`.
    /// @param punitiveFeeBps_ Must match `pendingFloorFees.punitiveFeeBps`.
    function applyFloorFees(uint24 proportionalFeeBps_, uint24 punitiveFeeBps_) external restricted {
        PendingFloorFees memory pending = pendingFloorFees;
        if (!pending.exists) revert NoPendingPolicyParam(PARAM_PROPORTIONAL_FEE_BPS);
        if (pending.proportionalFeeBps != proportionalFeeBps_ || pending.punitiveFeeBps != punitiveFeeBps_) {
            revert PendingPolicyParamMismatch(PARAM_PROPORTIONAL_FEE_BPS);
        }
        _validateFloorFees(proportionalFeeBps_, punitiveFeeBps_);
        emit PolicyParamConfirmed(
            PARAM_PROPORTIONAL_FEE_BPS, pending.previousProportionalFeeBps, proportionalFeeBps_, pending.proposer
        );
        emit PolicyParamConfirmed(
            PARAM_PUNITIVE_FEE_BPS, pending.previousPunitiveFeeBps, punitiveFeeBps_, pending.proposer
        );
        proportionalFeeBps = proportionalFeeBps_;
        punitiveFeeBps = punitiveFeeBps_;
        delete pendingFloorFees;
    }

    /// @notice Hook governor binds a Chainlink token/USD feed (`token` = address(0) for native ETH).
    /// @dev Passing `feed` = address(0) clears the binding. Magnitude quotes fail-closed without a feed.
    function setPriceFeed(address token, address feed) external restricted {
        address previous = address(priceFeeds[token]);
        priceFeeds[token] = IAggregatorV3(feed);
        emit PriceFeedUpdated(token, previous, feed);
    }

    /// @notice Hook governor retunes Floor B's 1-hour activity window (and unused op-cap storage).
    /// @dev Window is seconds. Restricted to `_HOOK_GOVERNOR`. Changing the window does not
    ///      rewrite past `windowStart` — the current bucket expires against the new duration.
    function setActivityWindow(uint64 activityWindow_, uint32 maxOpsInWindow_) external restricted {
        _applyActivityWindow(activityWindow_, maxOpsInWindow_);
    }

    /// @notice Hook governor retunes Floor C's 24-hour USD window (BSA CTR-style aggregation).
    function setDailyWindow(uint64 dailyWindow_) external restricted {
        if (dailyWindow_ < MIN_DAILY_WINDOW || dailyWindow_ > MAX_DAILY_WINDOW) {
            revert DailyWindowInvalid();
        }
        emit DailyWindowUpdated(dailyWindow, dailyWindow_);
        dailyWindow = dailyWindow_;
    }

    /// @notice Hook governor retunes how old a Chainlink `updatedAt` may be before fail-closed.
    function setPriceStalenessThreshold(uint256 priceStalenessThreshold_) external restricted {
        if (priceStalenessThreshold_ == 0 || priceStalenessThreshold_ > MAX_PRICE_STALENESS) {
            revert PriceStalenessThresholdInvalid();
        }
        emit PriceStalenessThresholdUpdated(priceStalenessThreshold, priceStalenessThreshold_);
        priceStalenessThreshold = priceStalenessThreshold_;
    }

    /// @notice Hook governor grants or revokes trusted-router status.
    /// @dev Enablement is an *operational attestation*, not an on-chain proof (§3.5).
    ///      Before `trusted = true`, the governor must have reviewed that `router`:
    ///        - is a curated integrator (e.g. Uniswap Labs router), and
    ///        - `msgSender()` returns the real end-user and cannot be overwritten in-tx.
    ///      The contract only stores that attestation.
    ///
    ///      L-02: in production the AccessManager MUST configure an execution delay of
    ///      at least 48 hours on `_HOOK_GOVERNOR`. This contract cannot enforce that
    ///      delay itself; it lives on the manager's role grant.
    function setTrustedRouter(address router, bool trusted) external restricted {
        trustedRouters[router] = trusted;
        emit TrustedRouterUpdated(router, trusted);
    }

    /// @notice Governor registers a verified multisig that may be a swap subject (C-03).
    /// @dev L1 (on-chain): `_resolveWallet` enumerates Safe owners and applies
    ///      `multisigAggregation` to sanctions only. L2 (behavior) is not applied per
    ///      signer here. After owners pass L1, the subject remains this Safe address;
    ///      `_evaluate` reads only the Safe's own ComplianceOracle row.
    ///
    ///      Off-chain keeper MUST publish that Safe row as follows (not enforced here):
    ///        1) treat any signer with `updatedAt == 0` as unscored (not ALLOW, not score 0);
    ///        2) apply Mitigation A (elevate / friction, not ALLOW) for those unsigned signers;
    ///        3) take the maximum among those normalized signer scores;
    ///        4) `updateScore` that aggregate on the Safe address.
    ///      A new signer without history must push the aggregate up, not vanish as clean.
    function setTrustedMultisig(address account, MultisigType kind, bool trusted) external restricted {
        if (account == address(0)) revert MissingSwapSubject();
        if (trusted && kind == MultisigType.NONE) revert MissingSwapSubject();
        trustedMultisigs[account] =
            TrustedMultisig({trusted: trusted, kind: trusted ? kind : MultisigType.NONE});
        emit TrustedMultisigUpdated(account, kind, trusted);
    }

    /// @notice Governor sets whether every Safe owner must be unsanctioned, or any one suffices.
    /// @dev L1 sanctions only. Does not aggregate owner behavioral scores or REVERT-band.
    function setMultisigAggregation(MultisigAggregation aggregation) external restricted {
        emit MultisigAggregationUpdated(multisigAggregation, aggregation);
        multisigAggregation = aggregation;
    }

    /// @dev Immediate membership check. Does not use `restricted`, so propose is not delayed.
    function _requireComplianceOfficer() private view {
        (bool isMember,) = IAccessManager(authority()).hasRole(Roles._COMPLIANCE_OFFICER, msg.sender);
        if (!isMember) revert IAccessManaged.AccessManagedUnauthorized(msg.sender);
    }

    /// @dev `readyAt` is now + the officer's AccessManager execution delay (48h in Deploy).
    function _policyReadyAt() private view returns (uint48 readyAt) {
        (, uint32 delay) = IAccessManager(authority()).hasRole(Roles._COMPLIANCE_OFFICER, msg.sender);
        readyAt = uint48(block.timestamp) + delay;
    }

    function _emitPolicyScheduled(string memory name, uint256 previousValue, uint256 newValue) private {
        emit PolicyParamScheduled(name, previousValue, newValue, msg.sender, _policyReadyAt());
    }

    /// @dev Only numeric rules on the USD pair: FATF VA minimum on the fee floor, and revert > fee.
    function _validateUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) private pure {
        if (feeThreshold < MIN_UNSCORED_FEE_THRESHOLD) {
            revert UnscoredFeeThresholdBelowFatfMinimum(feeThreshold, MIN_UNSCORED_FEE_THRESHOLD);
        }
        if (revertThreshold <= feeThreshold) {
            revert UnscoredRevertMustExceedFee(feeThreshold, revertThreshold);
        }
    }

    /// @dev Only numeric rule on the fee pair: punitive must be strictly greater than proportional.
    function _validateFloorFees(uint24 proportionalFeeBps_, uint24 punitiveFeeBps_) private pure {
        if (punitiveFeeBps_ <= proportionalFeeBps_) {
            revert PunitiveFeeMustExceedProportional(proportionalFeeBps_, punitiveFeeBps_);
        }
    }

    /// @dev Shared constructor / governor write. Rejects 0 and values outside the published bounds.
    function _applyActivityWindow(uint64 activityWindow_, uint32 maxOpsInWindow_) private {
        if (activityWindow_ < MIN_ACTIVITY_WINDOW || activityWindow_ > MAX_ACTIVITY_WINDOW) {
            revert ActivityWindowInvalid();
        }
        if (maxOpsInWindow_ < MIN_MAX_OPS_IN_WINDOW || maxOpsInWindow_ > MAX_MAX_OPS_IN_WINDOW) {
            revert MaxOpsInWindowInvalid();
        }
        emit ActivityWindowUpdated(activityWindow, maxOpsInWindow, activityWindow_, maxOpsInWindow_);
        activityWindow = activityWindow_;
        maxOpsInWindow = maxOpsInWindow_;
    }
}
