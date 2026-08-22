// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {ISanctionRegistry} from "../../interfaces/registries/ISanctionRegistry.sol";
import {IComplianceOracle} from "../../interfaces/oracles/IComplianceOracle.sol";
import {IRiskPolicy} from "../../interfaces/policies/IRiskPolicy.sol";
import {IMsgSender} from "../../interfaces/external/IMsgSender.sol";
import {IGnosisSafeOwners} from "../../interfaces/external/IGnosisSafeOwners.sol";
import {IERC20Minimal} from "../../interfaces/external/IERC20Minimal.sol";
import {IAggregatorV3} from "../../interfaces/external/IAggregatorV3.sol";
import {FeeBps} from "../../libraries/FeeBps.sol";
import {HookDecision} from "../../libraries/HookDecision.sol";
import {UsdQuote} from "../../libraries/UsdQuote.sol";

/// @title Shared beforeSwap decision logic for AMLHook
/// @notice This is where the whitepaper's on-chain read path lives (§3.5 / §3.8 / §3.9).
///
/// @dev ═══════════════════════════════════════════════════════════════════════
///      READER'S GUIDE (why this contract exists)
///      ═══════════════════════════════════════════════════════════════════════
///
///      Uniswap v4 calls the hook at swap time. The hook must answer in the same
///      transaction: ALLOW (base fee), FEE_OVERRIDE (punitive/proportional fee),
///      or REVERT. It must NOT recompute the behavioral graph on-chain — that work
///      is off-chain (Oracle Keeper / COA). On-chain we only:
///        1) resolve WHO is swapping (end-user, never the router as subject),
///        2) screen L1 sanctions → read L2 score → decide L3 ternary,
///        3) close the keeper-latency gap with pool-local §3.8 signals.
///
///      Layers (whitepaper §3.2):
///        L1 SanctionRegistry  — static OFAC-style list; hit = REVERT before score
///        L2 ComplianceOracle  — keeper-written score / hop / feeBps / updatedAt
///        L3 RiskPolicy        — pure mapping score(+floors) → decision + fee
///        Hook-local           — Mitigations A & C (never-written, activity cap)
///                               Mitigations B & D are floors inside RiskPolicy
///                               Never-scored magnitude (3% / 8% / REVERT) is decided in
///                               RiskPolicy from hook-quoted USD (Chainlink, 8 decimals)
///
///      Why pool-local state? If the keeper has not yet published after a P2P
///      transfer (use-case Wallet D), a stale score 0 would wrongly ALLOW.
///      Activity counters + lastKnownBalance let the hook elevate ALLOW→FEE_OVERRIDE
///      without waiting for the oracle. Elevations never soften REVERT.
///
///      Governance: `AccessManaged` against the shared AccessManager.
///      `_HOOK_GOVERNOR` may retune thresholds / trusted routers only — not the
///      swap path itself (that is fixed in bytecode).
///
///      Uniswap-facing surface (AmlHook must use these, in this order):
///        `_beginSwap`  — resolve subject + L1/L2/L3 + mitigations A–D
///        `_endSwap`    — record activity, refresh inflow baseline, emit SwapObserved
///      Leaf helpers (`_evaluate*`, `_recordActivity`, `_updateKnownBalance`) stay
///      `internal` for the unit harness. Inverting `_endSwap`'s three steps, or
///      skipping `_beginSwap`, is a silent mitigation break — do not call the leaves
///      from the Uniswap callbacks.
abstract contract AmlHookLogic is AccessManaged, Pausable {
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
    /// @dev Mitigation B (§3.8). Default 120s (H-04). Validators can nudge `block.timestamp`
    ///      within the protocol's allowed drift; a very short threshold is therefore
    ///      manipulable. `_HOOK_GOVERNOR` may retune within `[1, MAX_STALENESS]`.
    uint256 public stalenessThreshold;
    uint256 public constant DEFAULT_STALENESS = 120;
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

    /// @notice Rolling window for per-wallet pool activity counters (seconds).
    /// @dev Mitigation C (§3.8): catch burst swaps across consecutive blocks while
    ///      the keeper has not yet moved the score tier. `_HOOK_GOVERNOR` retunes
    ///      via `setActivityWindow` (default 1 hour; bounds `[MIN, MAX]`).
    uint64 public activityWindow;

    /// @notice Ops inside the activity window that force FEE_OVERRIDE instead of ALLOW.
    /// @dev Why a cap: without it, an attacker can spam ALLOW swaps under a lagging
    ///      clean score. Default 3 matches the local deploy / whitepaper example.
    ///      The next swap after this many completed ops pays 8%. Governor-retunable.
    uint32 public maxOpsInWindow;

    uint64 public constant DEFAULT_ACTIVITY_WINDOW = 1 hours;
    uint32 public constant DEFAULT_MAX_OPS_IN_WINDOW = 3;
    uint64 public constant MIN_ACTIVITY_WINDOW = 60;
    uint64 public constant MAX_ACTIVITY_WINDOW = 7 days;
    uint32 public constant MIN_MAX_OPS_IN_WINDOW = 1;
    uint32 public constant MAX_MAX_OPS_IN_WINDOW = 100;

    /// @notice USD-8 floor below which an unscored swap pays the reduced 3% latency fee.
    /// @dev Chainlink 8 decimals (1_000e8 = $1,000). GAFI Rec. 10 / CDD-aligned dust band.
    uint256 public unscoredFeeThreshold;

    /// @notice USD-8 floor at which an unscored wallet (or D inflow) is REVERTed.
    /// @dev Default 25_000e8 = $25,000. Applies when oracle `updatedAt == 0` (this swap +
    ///      window USD) or when Mitigation D inbound USD is at/above the floor.
    uint256 public unscoredRevertThreshold;

    /// @notice Chainlink token/USD feed per specified-currency token (`address(0)` = native ETH).
    /// @dev Governor-attested. Missing or stale feed is fail-closed for magnitude quotes.
    mapping(address => IAggregatorV3) public priceFeeds;

    /// @notice Max age of `latestRoundData.updatedAt` before a feed is treated as stale (seconds).
    /// @dev Distinct from score `stalenessThreshold` / WalletRisk.updatedAt. Default 3600.
    uint256 public priceStalenessThreshold;

    uint256 public constant DEFAULT_USD_FEE_THRESHOLD = 1_000e8;
    uint256 public constant DEFAULT_USD_REVERT_THRESHOLD = 25_000e8;
    uint256 public constant DEFAULT_PRICE_STALENESS = 3600;
    uint256 public constant MAX_PRICE_STALENESS = 24 hours;

    /// @notice Inbound USD share (bps of current USD-8 bag) that flags a medium-risk increment.
    /// @dev Mitigation D (§3.8) / use-case Wallet D. Default 5000 = 50% of current USD.
    ///      Medium increment → FEE_OVERRIDE (differential). Inbound USD ≥ revert floor → REVERT.
    uint256 public inflowThresholdBps;

    /// @dev Default punitive fee when elevating ALLOW due to hook-local latency mitigations.
    ///      800 bps = 8% — designed product fee when keeper omitted `feeBps` (Wallet D path).
    ///      Same constant as RiskPolicy (`FeeBps.LATENCY`) so A/C cannot drift from B/D.
    uint24 public constant LATENCY_FEE_BPS = FeeBps.LATENCY;

    /// @dev Per-wallet pool activity for Mitigation C and unscored structuring volume.
    ///      Independent of the oracle so the hook can still elevate / block while
    ///      `updateScore` is pending. `epoch` bumps when the window resets so per-token
    ///      volume from a previous window is ignored without a second accumulator.
    struct PoolActivity {
        uint64 windowStart;
        uint32 opCount;
        uint64 lastSwapAt;
        uint32 epoch;
        /// @dev Sum of settled specified amounts quoted to USD-8 at each afterSwap.
        ///      `type(uint256).max` is a fail-closed sentinel (quote failed while recording).
        uint256 volumeUsd;
    }

    /// @dev Volume of the specified swap currency inside the current activity window.
    struct TokenVolume {
        uint32 epoch;
        uint256 amount;
    }

    mapping(address => PoolActivity) internal _activity;
    mapping(address => mapping(address => TokenVolume)) internal _windowVolume;

    /// @notice Last observed ERC-20 balance per wallet and token (inflow heuristic baseline).
    /// @dev Written in afterSwap so the *next* beforeSwap can measure a sudden increase.
    mapping(address => mapping(address => uint256)) public lastKnownBalance;

    /// @notice Timestamp when `lastKnownBalance` was last written for wallet/token.
    /// @dev Compared to oracle `updatedAt`: if the score is older than this baseline,
    ///      the keeper has not yet incorporated the inflow → Mitigation D can fire.
    mapping(address => mapping(address => uint256)) public lastKnownBalanceTimestamp;

    error WalletBlocked(address wallet, uint8 score, string reason);
    error SanctionHit(address wallet);
    /// @notice Never-scored wallet: assessed USD-8 (this swap + window) is at/above `unscoredRevertThreshold`.
    /// @dev Index this selector on reverted txs — a log would be discarded by the revert
    ///      (same reason `WalletBlocked` / `SanctionHit` are errors, not events).
    error UnscoredMagnitudeBlocked(address wallet, uint256 assessedUsd, uint256 threshold);
    /// @notice Published score, but inbound USD-8 since baseline is at/above `unscoredRevertThreshold`
    ///         and the oracle timestamp still predates that baseline (Mitigation D absolute floor).
    error InflowMagnitudeBlocked(address wallet, uint256 inflowUsd, uint256 threshold);
    /// @notice Magnitude quote failed (no feed, stale feed, or invalid answer). Fail-closed.
    error MagnitudeQuoteFailed(address token, bytes32 reason);
    error UnscoredThresholdsInvalid();
    error PriceStalenessThresholdInvalid();
    error ActivityWindowInvalid();
    error MaxOpsInWindowInvalid();
    /// @notice Caller is not a trusted router — no end-user can be resolved (fail-closed §3.5).
    error MissingSwapSubject();
    /// @notice Trusted router `msgSender()` reverted or returned zero — fail closed.
    error TrustedRouterSubjectFailed(address router);
    error InflowThresholdOutOfRange();
    error StalenessThresholdTooLow();
    error StalenessThresholdTooHigh();
    error BaselineIntervalZero();

    event MinBaselineIntervalUpdated(uint64 previous, uint64 current);
    event TrustedMultisigUpdated(address indexed account, MultisigType kind, bool trusted);
    event MultisigAggregationUpdated(MultisigAggregation previous, MultisigAggregation current);

    event StalenessThresholdUpdated(uint256 previous, uint256 current);
    event InflowThresholdUpdated(uint256 previous, uint256 current);
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
    event TrustedRouterUpdated(address indexed router, bool trusted);

    /// @notice afterSwap audit trail for off-chain scoring + reporting (§3.4 / §3.6 / §3.9 Step 7).
    /// @dev This is the "film" the COA watches: who swapped, at what score/decision/fee/hop.
    event SwapObserved(
        address indexed wallet,
        uint8 score,
        HookDecision decision,
        uint24 feeBps,
        uint8 hopDistance,
        address origin
    );

    /// @notice ALLOW was elevated to FEE_OVERRIDE by a §3.8 latency mitigation.
    /// @dev Reason codes let operators / regulators see *why* friction was applied
    ///      without a score-band FEE_OVERRIDE.
    event LatencyMitigationApplied(
        address indexed wallet, bytes32 reason, uint24 feeBps, uint8 oracleScore
    );

    /// @notice Significant balance increase detected while the oracle score predates that baseline (Mitigation D).
    event InflowHeuristicTriggered(address indexed wallet, uint256 deltaBps, uint256 timestamp);

    bytes32 public constant REASON_SCORE_NEVER_WRITTEN = keccak256("SCORE_NEVER_WRITTEN");
    bytes32 public constant REASON_STALE_WITH_POOL_ACTIVITY = keccak256("STALE_WITH_POOL_ACTIVITY");
    bytes32 public constant REASON_ACTIVITY_WINDOW_CAP = keccak256("ACTIVITY_WINDOW_CAP");
    bytes32 public constant QUOTE_NO_FEED = keccak256("NO_FEED");
    bytes32 public constant QUOTE_STALE_FEED = keccak256("STALE_FEED");
    bytes32 public constant QUOTE_BAD_PRICE = keccak256("BAD_PRICE");
    bytes32 public constant QUOTE_WINDOW_FAILED = keccak256("WINDOW_FAILED");

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
        // Sensible defaults if deploy passes 0 (H-04: 120s minimum recommended).
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
        inflowThresholdBps = 5000; // 50% — Wallet D / Mitigation D default
        // USD-8 floors (Chainlink decimals). Governor retunes via setUnscoredThresholds.
        unscoredFeeThreshold = DEFAULT_USD_FEE_THRESHOLD;
        unscoredRevertThreshold = DEFAULT_USD_REVERT_THRESHOLD;
        priceStalenessThreshold = DEFAULT_PRICE_STALENESS;
        emit StalenessThresholdUpdated(0, stalenessThreshold);
        emit InflowThresholdUpdated(0, inflowThresholdBps);
        emit UnscoredThresholdsUpdated(0, 0, unscoredFeeThreshold, unscoredRevertThreshold);
        emit PriceStalenessThresholdUpdated(0, priceStalenessThreshold);
    }

    /// @notice Hook governor retunes Mitigation B staleness window (§3.8).
    /// @dev Why restricted: only `_HOOK_GOVERNOR` should change how aggressively we treat
    ///      lagging scores (institutional 30–60s vs retail minutes). Keepers must not.
    ///      H-04: validators can bias `block.timestamp`; do not set this below ~120s in
    ///      production without accepting that trade-off.
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

    /// @notice Hook governor retunes never-scored fee / revert floors in USD-8 (Chainlink decimals).
    /// @dev `revertThreshold == 0` disables the hard block. Otherwise `feeThreshold` must be
    ///      strictly below `revertThreshold`. Restricted to `_HOOK_GOVERNOR`, not a contract owner.
    function setUnscoredThresholds(uint256 feeThreshold, uint256 revertThreshold) external restricted {
        if (revertThreshold != 0 && feeThreshold >= revertThreshold) revert UnscoredThresholdsInvalid();
        emit UnscoredThresholdsUpdated(
            unscoredFeeThreshold, unscoredRevertThreshold, feeThreshold, revertThreshold
        );
        unscoredFeeThreshold = feeThreshold;
        unscoredRevertThreshold = revertThreshold;
    }

    /// @notice Hook governor binds a Chainlink token/USD feed (`token` = address(0) for native ETH).
    /// @dev Passing `feed` = address(0) clears the binding. Magnitude quotes fail-closed without a feed.
    function setPriceFeed(address token, address feed) external restricted {
        address previous = address(priceFeeds[token]);
        priceFeeds[token] = IAggregatorV3(feed);
        emit PriceFeedUpdated(token, previous, feed);
    }

    /// @notice Hook governor retunes Mitigation C's activity window and op cap (§3.8).
    /// @dev Window is seconds; `maxOpsInWindow_` completed ops force the next swap to 8%.
    ///      Restricted to `_HOOK_GOVERNOR`. Changing the window does not rewrite past
    ///      `windowStart` — the current bucket expires against the new duration.
    function setActivityWindow(uint64 activityWindow_, uint32 maxOpsInWindow_) external restricted {
        _applyActivityWindow(activityWindow_, maxOpsInWindow_);
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

    /// @notice Resolve the compliance subject for beforeSwap (§3.5).
    /// @dev The only subject source is `IMsgSender(router).msgSender()` on a trusted router.
    ///      Uniswap `hookData` is ignored: callers cannot declare the end-user.
    ///      Untrusted initiator → `MissingSwapSubject`. Revert or zero msgSender →
    ///      `TrustedRouterSubjectFailed`. Never score the router itself.
    ///      A contract subject must be a trusted multisig whose owners pass L1
    ///      (`_requireMultisigOwnersClean`). The returned wallet is still the Safe;
    ///      L2 score / Mitigations A–D run on that address, not per signer.
    /// @param router PoolManager-reported swap initiator (`sender` in beforeSwap).
    function _resolveWallet(address router) internal view returns (address wallet) {
        if (!trustedRouters[router]) revert MissingSwapSubject();

        try IMsgSender(router).msgSender() returns (address subject) {
            wallet = subject;
        } catch {
            revert TrustedRouterSubjectFailed(router);
        }
        if (wallet == address(0)) revert TrustedRouterSubjectFailed(router);

        if (wallet.code.length == 0) return wallet;

        TrustedMultisig memory ms = trustedMultisigs[wallet];
        if (!ms.trusted) revert MissingSwapSubject();
        _requireMultisigOwnersClean(wallet, ms.kind);
    }

    /// @dev C-03 L1: enumerate Safe owners and apply `multisigAggregation` to sanctions only.
    ///      ALL_CLEAN: any sanctioned owner → `SanctionHit(owner)`.
    ///      ANY_CLEAN: one unsanctioned owner is enough; if every owner is sanctioned →
    ///      `SanctionHit` on the first sanctioned owner. No per-owner score / REVERT-band.
    function _requireMultisigOwnersClean(address wallet, MultisigType kind) private view {
        address[] memory owners;
        if (kind == MultisigType.GNOSIS_SAFE) {
            try IGnosisSafeOwners(wallet).getOwners() returns (address[] memory o) {
                owners = o;
            } catch {
                revert MissingSwapSubject();
            }
        } else {
            revert MissingSwapSubject();
        }
        if (owners.length == 0) revert MissingSwapSubject();

        bool anyClean;
        address firstSanctioned;
        for (uint256 i; i < owners.length; ++i) {
            if (_ownerIsClean(owners[i])) {
                anyClean = true;
            } else {
                if (firstSanctioned == address(0)) firstSanctioned = owners[i];
                if (multisigAggregation == MultisigAggregation.ALL_CLEAN) {
                    revert SanctionHit(owners[i]);
                }
            }
        }
        if (multisigAggregation == MultisigAggregation.ANY_CLEAN && !anyClean) {
            revert SanctionHit(firstSanctioned);
        }
    }

    /// @dev L1 only: an owner is clean when it is not sanctioned. Score / `updatedAt` are ignored.
    function _ownerIsClean(address owner_) private view returns (bool) {
        return !sanctionRegistry.isSanctioned(owner_);
    }

    /// @notice Reverts if `wallet` is on the L1 sanctions list (§3.2 / §4.1).
    /// @dev Shared by the swap path (`_evaluateCore`) and LP entry (`AmlHook._beforeAddLiquidity`).
    ///      LP exit is not screened. Fail closed: a sanctions hit must never consult the
    ///      behavioral score or any other layer. Blocked swaps revert (`SanctionHit` /
    ///      `WalletBlocked`); off-chain monitors should index those custom errors on reverted
    ///      txs — a log would be discarded by the revert.
    function _requireNotSanctioned(address wallet) internal view {
        if (sanctionRegistry.isSanctioned(wallet)) revert SanctionHit(wallet);
    }

    /// @dev Uniswap-facing swap snapshot. Built by `_beginSwap`, consumed by `_endSwap`.
    struct SwapEvaluation {
        address wallet;
        address token;
        HookDecision decision;
        uint24 feeBps;
        IComplianceOracle.WalletRisk risk;
        bool inflowTriggered;
    }

    /// @notice beforeSwap compliance entry: resolve the subject, then decide (events on).
    /// @dev Order is fixed here so AmlHook cannot evaluate a router as the subject or
    ///      skip mitigations. `token` is the swap input (address(0) skips Mitigation D).
    ///      `volumeToken` + `amount` are the specified-currency magnitude (native units).
    function _beginSwap(address router, address token, address volumeToken, uint256 amount)
        internal
        returns (SwapEvaluation memory ev)
    {
        ev.wallet = _resolveWallet(router);
        ev.token = token;
        (ev.decision, ev.feeBps, ev.risk, ev.inflowTriggered) =
            _evaluateWithMitigationEvents(ev.wallet, token, volumeToken, amount);
    }

    /// @notice afterSwap compliance exit: activity → baseline → SwapObserved, in that order.
    /// @dev Activity must land before the next beforeSwap sees Mitigation C / structuring
    ///      volume. Baseline must wait until after this swap's inflow flag is consumed (H-02).
    ///      Observation is last so the COA trail reflects the settled decision.
    function _endSwap(SwapEvaluation memory ev, address volumeToken, uint256 settledAmount) internal {
        _recordActivity(ev.wallet, volumeToken, settledAmount);
        _updateKnownBalance(ev.wallet, ev.token, ev.inflowTriggered);
        _emitSwapObserved(ev.wallet, ev.decision, ev.feeBps, ev.risk);
    }

    /// @notice Per-wallet pool activity tracked by the hook (independent of the oracle; Mitigation C).
    function poolActivity(address wallet)
        external
        view
        returns (uint64 windowStart, uint32 opCount, uint64 lastSwapAt)
    {
        PoolActivity storage a = _activity[wallet];
        return (a.windowStart, a.opCount, a.lastSwapAt);
    }

    /// @notice Specified-currency volume already settled for `wallet` in the current activity window.
    function windowVolume(address wallet, address token) external view returns (uint256) {
        return _volumeInCurrentWindow(wallet, token);
    }

    /// @notice Window volume already quoted to USD-8 (sum of per-swap quotes, not mixed native units).
    function windowVolumeUsd(address wallet) external view returns (uint256) {
        return _usdInCurrentWindow(wallet);
    }

    /// @notice Evaluate a swap subject (view path). Reverts on REVERT / sanctions.
    /// @param wallet End-user compliance subject — not the router (§3.5).
    /// @param token Input token of the swap (address(0) skips the inflow heuristic).
    /// @return decision ALLOW or FEE_OVERRIDE
    /// @return feeBps Override fee when FEE_OVERRIDE; 0 on ALLOW
    /// @return risk Snapshot from the oracle
    /// @dev PIPELINE (same order as whitepaper §3.5 / §3.9 Step 5):
    ///      L1 isSanctioned → L2 getRisk → derive isStale / ops / inflow / assessed volume →
    ///      L3 RiskPolicy.decide → if still ALLOW, apply hook-local A & C.
    function _evaluate(address wallet, address token)
        internal
        view
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk
        )
    {
        return _evaluate(wallet, token, token, 0);
    }

    /// @notice View evaluate with specified-currency magnitude (`volumeToken` + `amount`).
    function _evaluate(address wallet, address token, address volumeToken, uint256 amount)
        internal
        view
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk
        )
    {
        _requireNotPaused();
        EvalSignals memory sig;
        (decision, feeBps, risk, sig) = _evaluateCore(wallet, token, volumeToken, amount);
        if (decision == HookDecision.ALLOW) {
            (decision, feeBps) = _applyHookLocalMitigations(wallet, risk, sig.operationCount);
        }
    }

    /// @dev Shared L1 → L3 path. Hook-local A/C are applied by the caller so the view
    ///      and event-emitting wrappers cannot drift.
    struct EvalSignals {
        bool isStale;
        uint32 operationCount;
        bool hasSignificantInflow;
        uint256 deltaBps;
        uint256 assessedUsd;
        uint256 inflowDelta;
        uint256 inflowUsd;
    }

    function _evaluateCore(address wallet, address token, address volumeToken, uint256 amount)
        private
        view
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            EvalSignals memory sig
        )
    {
        // ── Layer 1 — static sanctions (§3.2 / §4.1) ─────────────────────────
        // Fail closed: OFAC/SDN-style hit must not consult the behavioral score.
        _requireNotSanctioned(wallet);

        // ── Layer 2 — keeper-written score (§3.2 / §3.8) ─────────────────────
        // Hook never computes N-hop decay here; it only reads what the keeper published.
        risk = complianceOracle.getRisk(wallet);

        // Derive §3.8 signals the pure RiskPolicy cannot observe by itself
        // (RiskPolicy must stay free of block.timestamp / external calls).
        sig.operationCount = _opsInCurrentWindow(wallet);
        sig.isStale = _isStale(risk.updatedAt);
        (sig.hasSignificantInflow, sig.deltaBps, sig.inflowDelta) = _inflowSignal(wallet, token, risk.updatedAt);

        // USD-8 quotes for magnitude floors. Fail-closed: missing/stale/invalid feed is treated
        // as exceeding the high threshold (same principle as SanctionRegistry).
        bool neverScored = risk.updatedAt == 0;
        if (neverScored) {
            (sig.assessedUsd, ) = _requireUsdQuote(volumeToken, amount, _usdInCurrentWindow(wallet));
        } else if (sig.inflowDelta > 0) {
            // Both legs at the current feed: 50% is inbound USD / current USD, not native units.
            (sig.inflowUsd, ) = _requireUsdQuote(token, sig.inflowDelta, 0);
            uint256 currentBal = IERC20Minimal(token).balanceOf(wallet);
            (uint256 currentUsd, ) = _requireUsdQuote(token, currentBal, 0);
            if (currentUsd > 0) {
                sig.deltaBps = (sig.inflowUsd * 10_000) / currentUsd;
                sig.hasSignificantInflow = sig.deltaBps > inflowThresholdBps;
            } else {
                sig.hasSignificantInflow = false;
            }
        }

        // ── Layer 3 — ternary bands + floors B/D + USD magnitude ─────────────
        (decision, feeBps) = riskPolicy.decide(
            risk.score,
            risk.feeBps,
            sig.isStale,
            sig.operationCount,
            sig.hasSignificantInflow,
            neverScored,
            sig.assessedUsd,
            sig.inflowUsd,
            unscoredFeeThreshold,
            unscoredRevertThreshold
        );

        // Distinct revert reasons: score band vs unknown size vs scored + large unreflected inflow.
        if (decision == HookDecision.REVERT) {
            if (neverScored) {
                revert UnscoredMagnitudeBlocked(wallet, sig.assessedUsd, unscoredRevertThreshold);
            }
            if (sig.inflowUsd >= unscoredRevertThreshold && unscoredRevertThreshold != 0) {
                revert InflowMagnitudeBlocked(wallet, sig.inflowUsd, unscoredRevertThreshold);
            }
            revert WalletBlocked(wallet, risk.score, "SCORE_REVERT_BAND");
        }
    }

    /// @dev Elevates ALLOW → FEE_OVERRIDE for hook-local signals not passed into RiskPolicy.
    ///      A: never-written score (unknown ≠ confirmed-clean).
    ///      C: activity-window cap (burst while keeper lags).
    ///      B (stale+ops) and D (inflow) already floored inside RiskPolicy.decide.
    function _applyHookLocalMitigations(
        address wallet,
        IComplianceOracle.WalletRisk memory risk,
        uint32 operationCount
    ) internal view returns (HookDecision decision, uint24 feeBps) {
        decision = HookDecision.ALLOW;
        feeBps = 0;

        // Mitigation A: updatedAt == 0 means "never published", not "score 0 clean".
        // A legitimately clean wallet must be written explicitly with score 0 + non-zero updatedAt.
        if (risk.updatedAt == 0) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }

        // Mitigation C: too many ops in the rolling window → economic friction, not hard block.
        if (operationCount >= maxOpsInWindow) {
            return (HookDecision.FEE_OVERRIDE, _latencyFee(risk));
        }
    }

    /// @dev Same checks as `_evaluate`, but emits mitigation / inflow events for the audit trail.
    ///      Used by beforeSwap so operators can prove *why* FEE_OVERRIDE was applied (§3.6).
    function _evaluateWithMitigationEvents(address wallet, address token)
        internal
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            bool inflowTriggered
        )
    {
        return _evaluateWithMitigationEvents(wallet, token, token, 0);
    }

    /// @notice Live evaluate: same as `_evaluate` plus mitigation / inflow events for the audit trail.
    function _evaluateWithMitigationEvents(
        address wallet,
        address token,
        address volumeToken,
        uint256 amount
    )
        internal
        returns (
            HookDecision decision,
            uint24 feeBps,
            IComplianceOracle.WalletRisk memory risk,
            bool inflowTriggered
        )
    {
        _requireNotPaused();
        EvalSignals memory sig;
        (decision, feeBps, risk, sig) = _evaluateCore(wallet, token, volumeToken, amount);
        inflowTriggered = sig.hasSignificantInflow;

        // Mitigation D audit: generic "recent funds → swap" pattern (not origin attribution).
        if (sig.hasSignificantInflow) {
            emit InflowHeuristicTriggered(wallet, sig.deltaBps, block.timestamp);
        }

        // Never-scored USD bands are decided in RiskPolicy (3% / 8%); emit the A reason here.
        if (risk.updatedAt == 0 && decision == HookDecision.FEE_OVERRIDE) {
            emit LatencyMitigationApplied(wallet, REASON_SCORE_NEVER_WRITTEN, feeBps, risk.score);
        }

        // Audit when RiskPolicy floored ALLOW→FEE_OVERRIDE via Mitigation B (score still ≤ 30).
        if (
            risk.score <= 30 && sig.isStale && sig.operationCount > 0
                && decision == HookDecision.FEE_OVERRIDE
        ) {
            emit LatencyMitigationApplied(
                wallet, REASON_STALE_WITH_POOL_ACTIVITY, feeBps, risk.score
            );
        }

        if (decision != HookDecision.ALLOW) {
            return (decision, feeBps, risk, inflowTriggered);
        }

        (decision, feeBps) = _applyHookLocalMitigations(wallet, risk, sig.operationCount);
        if (decision == HookDecision.ALLOW) {
            return (decision, 0, risk, inflowTriggered);
        }

        bytes32 reason = risk.updatedAt == 0 ? REASON_SCORE_NEVER_WRITTEN : REASON_ACTIVITY_WINDOW_CAP;
        emit LatencyMitigationApplied(wallet, reason, feeBps, risk.score);
        return (decision, feeBps, risk, inflowTriggered);
    }

    /// @dev Prefer keeper-written feeBps when in range; else 8% latency fee
    ///      (Wallet D / §3.8 designed product behavior when keeper omitted fee).
    function _latencyFee(IComplianceOracle.WalletRisk memory risk) private pure returns (uint24) {
        return FeeBps.resolveLatencyFee(risk.feeBps);
    }

    /// @dev Mitigation B freshness: score older than `stalenessThreshold` is stale.
    ///      updatedAt == 0 is also treated stale (overlaps Mitigation A's "never written").
    function _isStale(uint64 updatedAt) private view returns (bool) {
        if (updatedAt == 0) return true;
        return block.timestamp > uint256(updatedAt) + stalenessThreshold;
    }

    /// @notice Balance-delta inflow heuristic — oracle-latency Mitigation D (§3.8 / Wallet D).
    /// @dev WHY: Mitigations A–C miss the path "wallet was published clean, then receives a large
    ///      P2P transfer, then swaps before keeper updateScore". Token delta is quoted to USD-8.
    ///      Inbound USD / current USD > inflowThresholdBps (default 50%) → medium risk → FEE_OVERRIDE
    ///      (differential). Inbound USD ≥ unscoredRevertThreshold → REVERT.
    ///      Extra gas for balanceOf is intentional. Skipped when `token` is address(0).
    function _inflowSignal(address wallet, address token, uint64 scoreUpdatedAt)
        private
        view
        returns (bool hasSignificantInflow, uint256 deltaBps, uint256 inflowDelta)
    {
        if (token == address(0) || token.code.length == 0) {
            return (false, 0, 0);
        }

        uint256 currentBalance = IERC20Minimal(token).balanceOf(wallet);
        if (currentBalance == 0) {
            return (false, 0, 0);
        }

        uint256 previous = lastKnownBalance[wallet][token];
        uint256 delta = currentBalance > previous ? currentBalance - previous : 0;
        // Provisional token-unit share; `_evaluateCore` overwrites with inbound USD / current USD.
        deltaBps = (delta * 10_000) / currentBalance;

        // Mitigation A already covers never-written scores. Without a baseline there is no
        // inflow to measure — a new wallet's first swap would otherwise look like a 100% delta.
        uint256 baselineTs = lastKnownBalanceTimestamp[wallet][token];
        if (scoreUpdatedAt == 0 || baselineTs == 0) {
            return (false, 0, 0);
        }
        // Oracle already newer than the baseline: inflow was incorporated; do not fee or block on it.
        if (uint256(scoreUpdatedAt) > baselineTs) {
            return (false, deltaBps, 0);
        }
        inflowDelta = delta;
        if (deltaBps > inflowThresholdBps) {
            hasSignificantInflow = true;
        }
    }

    /// @dev Ops counted inside the current Mitigation C window (0 if window elapsed / never started).
    /// @dev Ops still inside `activityWindow`, or 0 if the window never started / already elapsed.
    function _opsInCurrentWindow(address wallet) private view returns (uint32) {
        PoolActivity storage a = _activity[wallet];
        if (a.windowStart == 0) return 0;
        if (block.timestamp >= uint256(a.windowStart) + uint256(activityWindow)) return 0;
        return a.opCount;
    }

    /// @dev Specified-currency volume still inside the Mitigation C / structuring window.
    function _volumeInCurrentWindow(address wallet, address token) private view returns (uint256) {
        PoolActivity storage a = _activity[wallet];
        if (a.windowStart == 0) return 0;
        if (block.timestamp >= uint256(a.windowStart) + uint256(activityWindow)) return 0;
        TokenVolume storage v = _windowVolume[wallet][token];
        if (v.epoch != a.epoch) return 0;
        return v.amount;
    }

    /// @dev USD-8 already recorded in the current activity window (0 if elapsed / never started).
    function _usdInCurrentWindow(address wallet) private view returns (uint256) {
        PoolActivity storage a = _activity[wallet];
        if (a.windowStart == 0) return 0;
        if (block.timestamp >= uint256(a.windowStart) + uint256(activityWindow)) return 0;
        return a.volumeUsd;
    }

    /// @dev Quote `amount` of `token` to USD-8 and add `windowUsd`. Reverts fail-closed on any quote error.
    function _requireUsdQuote(address token, uint256 amount, uint256 windowUsd)
        private
        view
        returns (uint256 assessedUsd, bytes32)
    {
        if (windowUsd == type(uint256).max) {
            revert MagnitudeQuoteFailed(token, QUOTE_WINDOW_FAILED);
        }
        (uint256 usd, bytes32 reason) = _tryQuoteUsd(token, amount);
        if (reason != bytes32(0)) revert MagnitudeQuoteFailed(token, reason);
        return (windowUsd + usd, bytes32(0));
    }

    /// @dev Chainlink latestRoundData → USD-8. `reason != 0` means the quote must fail-closed.
    function _tryQuoteUsd(address token, uint256 amount) private view returns (uint256 usd, bytes32 reason) {
        IAggregatorV3 feed = priceFeeds[token];
        if (address(feed) == address(0)) return (0, QUOTE_NO_FEED);

        uint80 roundId;
        int256 answer;
        uint256 updatedAt;
        uint80 answeredInRound;
        try feed.latestRoundData() returns (uint80 r, int256 a, uint256, uint256 u, uint80 ar) {
            roundId = r;
            answer = a;
            updatedAt = u;
            answeredInRound = ar;
        } catch {
            return (0, QUOTE_BAD_PRICE);
        }

        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) {
            return (0, QUOTE_BAD_PRICE);
        }
        if (block.timestamp > updatedAt + priceStalenessThreshold) {
            return (0, QUOTE_STALE_FEED);
        }

        uint8 feedDecimals;
        try feed.decimals() returns (uint8 d) {
            feedDecimals = d;
        } catch {
            return (0, QUOTE_BAD_PRICE);
        }
        if (feedDecimals > 18) return (0, QUOTE_BAD_PRICE);

        (uint8 tokenDecimals, bool decOk) = _tokenDecimals(token);
        if (!decOk) return (0, QUOTE_BAD_PRICE);

        usd = UsdQuote.toUsd8(amount, tokenDecimals, uint256(answer), feedDecimals);
    }

    /// @dev Native ETH (`address(0)`) and no-code currencies are 18 decimals. ERC-20 `decimals()`
    ///      is fail-closed if missing or > 36. A feed is still required to quote.
    function _tokenDecimals(address token) private view returns (uint8 decimals_, bool ok) {
        if (token == address(0) || token.code.length == 0) return (18, true);
        try IERC20Minimal(token).decimals() returns (uint8 d) {
            if (d > 36) return (0, false);
            return (d, true);
        } catch {
            return (0, false);
        }
    }

    /// @notice Record a successful pool swap for latency / activity mitigations (afterSwap; §3.9 Step 7).
    /// @dev Why afterSwap (not beforeSwap): only count ops that actually settled. Resets the
    ///      rolling window when it has elapsed so old bursts do not permanently elevate.
    ///      `amount` is added to the same window (per specified token) for never-scored structuring.
    /// @notice Record one settled op with no volume (Mitigation C tests / zero-size path).
    function _recordActivity(address wallet) internal {
        _recordActivity(wallet, address(0), 0);
    }

    function _recordActivity(address wallet, address token, uint256 amount) internal {
        PoolActivity storage a = _activity[wallet];
        if (a.windowStart == 0 || block.timestamp >= uint256(a.windowStart) + uint256(activityWindow)) {
            if (a.windowStart != 0) {
                a.epoch += 1;
            }
            a.windowStart = uint64(block.timestamp);
            a.opCount = 1;
            a.volumeUsd = 0;
        } else {
            a.opCount += 1;
        }
        a.lastSwapAt = uint64(block.timestamp);
        if (amount == 0) return;
        _windowVolume[wallet][token] =
            TokenVolume({epoch: a.epoch, amount: _volumeInCurrentWindow(wallet, token) + amount});
        (uint256 usd, bytes32 reason) = _tryQuoteUsd(token, amount);
        if (reason != bytes32(0)) {
            a.volumeUsd = type(uint256).max;
        } else if (a.volumeUsd != type(uint256).max) {
            a.volumeUsd += usd;
        }
    }

    /// @notice Refresh the Mitigation D baseline after a successful swap (afterSwap; §3.8).
    /// @dev H-02: skipped when this swap already triggered inflow (do not move the baseline
    ///      in the same transaction the heuristic fired). Also skipped until
    ///      `minBaselineInterval` has elapsed since the last write.
    function _updateKnownBalance(address wallet, address token, bool inflowTriggered) internal {
        if (inflowTriggered) return;
        if (token == address(0) || token.code.length == 0) return;
        uint256 lastTs = lastKnownBalanceTimestamp[wallet][token];
        if (lastTs != 0 && block.timestamp < lastTs + uint256(minBaselineInterval)) return;
        uint256 bal = IERC20Minimal(token).balanceOf(wallet);
        lastKnownBalance[wallet][token] = bal;
        lastKnownBalanceTimestamp[wallet][token] = block.timestamp;
    }

    /// @notice Emit afterSwap audit trail once settlement succeeded (§3.6 / §3.4).
    /// @dev Off-chain engine consumes this to update the wallet's cumulative risk before the next swap.
    function _emitSwapObserved(
        address wallet,
        HookDecision decision,
        uint24 feeBps,
        IComplianceOracle.WalletRisk memory risk
    ) internal {
        emit SwapObserved(
            wallet, risk.score, decision, feeBps, risk.hopDistance, risk.origin
        );
    }
}
