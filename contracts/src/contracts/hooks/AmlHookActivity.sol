// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookGovernance} from "./AmlHookGovernance.sol";
import {IERC20Minimal} from "../../interfaces/external/IERC20Minimal.sol";

/// @title Per-wallet activity and baseline tracking for the AML hook
/// @notice Holds the rolling 1-hour Floor B and 24-hour Floor C accumulators, plus
///         the Mitigation D inflow baseline. No governance setters live here.
/// @dev Sits between AmlHookGovernance and AmlHookLogic in the linear chain:
///      AmlHookGovernance → AmlHookActivity → AmlHookLogic → AmlHook
abstract contract AmlHookActivity is AmlHookGovernance {
    /// @dev Per-wallet hourly activity bucket (Floor B).
    ///      `epoch` bumps on window reset so stale token-volume entries are discarded.
    struct PoolActivity {
        uint64 windowStart;
        uint32 opCount;
        uint64 lastSwapAt;
        uint32 epoch;
        /// @dev Sum of settled specified amounts quoted to USD-8 at each afterSwap.
        ///      `type(uint256).max` is a fail-closed sentinel (quote failed while recording).
        uint256 volumeUsd;
    }

    /// @dev Per-wallet 24-hour USD accumulator (Floor C, BSA CTR-style).
    struct DailyActivity {
        uint64 windowStart;
        /// @dev `type(uint256).max` is a fail-closed sentinel (quote failed while recording).
        uint256 volumeUsd;
    }

    /// @dev Per-wallet, per-token volume inside the current activity window.
    struct TokenVolume {
        uint32 epoch;
        uint256 amount;
    }

    mapping(address => PoolActivity) internal _activity;
    mapping(address => DailyActivity) internal _daily;
    mapping(address => mapping(address => TokenVolume)) internal _windowVolume;

    /// @notice Last observed ERC-20 balance per wallet and token (inflow heuristic baseline).
    /// @dev Written in afterSwap so the *next* beforeSwap can measure a sudden increase.
    mapping(address => mapping(address => uint256)) public lastKnownBalance;

    /// @notice Timestamp when `lastKnownBalance` was last written for wallet/token.
    /// @dev Compared to oracle `updatedAt`: if the score is older than this baseline,
    ///      the keeper has not yet incorporated the inflow → Mitigation D can fire.
    mapping(address => mapping(address => uint256)) public lastKnownBalanceTimestamp;

    // ── Public views ─────────────────────────────────────────────────────────

    /// @notice Per-wallet pool activity tracked by the hook (independent of the oracle; Mitigation C).
    function poolActivity(address wallet)
        external
        view
        returns (uint64 windowStart, uint32 opCount, uint64 lastSwapAt)
    {
        PoolActivity storage act = _activity[wallet];
        return (act.windowStart, act.opCount, act.lastSwapAt);
    }

    /// @notice Specified-currency volume already settled for `wallet` in the current activity window.
    function windowVolume(address wallet, address token) external view returns (uint256) {
        return _volumeInCurrentWindow(wallet, token);
    }

    /// @notice Window volume already quoted to USD-8 (sum of per-swap quotes, not mixed native units).
    function windowVolumeUsd(address wallet) external view returns (uint256) {
        return _usdInCurrentWindow(wallet);
    }

    /// @notice USD-8 already recorded in the current 24-hour Floor C window.
    function dailyVolumeUsd(address wallet) external view returns (uint256) {
        return _usdInDailyWindow(wallet);
    }

    // ── Internal writers (called from AmlHookLogic via _endSwap) ─────────────

    /// @notice Record one settled op with no volume (Mitigation C tests / zero-size path).
    function _recordActivity(address wallet) internal {
        _recordActivity(wallet, address(0), 0);
    }

    /// @notice Record a successful pool swap for latency / activity mitigations (afterSwap; §3.9 Step 7).
    /// @dev Why afterSwap (not beforeSwap): only count ops that actually settled. Resets the
    ///      rolling window when it has elapsed so old bursts do not permanently elevate.
    ///      `amount` is added to the same window (per specified token) for never-scored structuring.
    function _recordActivity(address wallet, address token, uint256 amount) internal {
        PoolActivity storage act = _activity[wallet];
        bool windowElapsed = act.windowStart != 0
            && block.timestamp >= uint256(act.windowStart) + uint256(activityWindow);

        if (act.windowStart == 0 || windowElapsed) {
            if (act.windowStart != 0) act.epoch += 1;
            act.windowStart = uint64(block.timestamp);
            act.opCount = 1;
            act.volumeUsd = 0;
        } else {
            act.opCount += 1;
        }
        act.lastSwapAt = uint64(block.timestamp);

        if (amount == 0) return;

        _windowVolume[wallet][token] =
            TokenVolume({epoch: act.epoch, amount: _volumeInCurrentWindow(wallet, token) + amount});

        (uint256 usd, bytes32 quoteError) = _tryQuoteUsdRaw(token, amount);
        if (quoteError != bytes32(0)) {
            act.volumeUsd = type(uint256).max;
            _recordDailyUsd(wallet, type(uint256).max);
        } else if (act.volumeUsd != type(uint256).max) {
            act.volumeUsd += usd;
            _recordDailyUsd(wallet, usd);
        }
    }

    /// @notice Refresh the Mitigation D baseline after a successful swap (afterSwap; §3.8).
    /// @dev H-02: skipped when this swap already triggered inflow (do not move the baseline
    ///      in the same transaction the heuristic fired). Also skipped until
    ///      `minBaselineInterval` has elapsed since the last write.
    function _updateKnownBalance(address wallet, address token, bool inflowTriggered) internal {
        if (inflowTriggered) return;
        if (token == address(0) || token.code.length == 0) return;
        uint256 lastWriteTs = lastKnownBalanceTimestamp[wallet][token];
        if (lastWriteTs != 0 && block.timestamp < lastWriteTs + uint256(minBaselineInterval)) return;
        uint256 currentBalance = IERC20Minimal(token).balanceOf(wallet);
        lastKnownBalance[wallet][token] = currentBalance;
        lastKnownBalanceTimestamp[wallet][token] = block.timestamp;
    }

    // ── Internal read helpers (called from AmlHookLogic's evaluation pipeline) ──

    /// @dev Ops still inside the Floor B window, or 0 if never started / already elapsed.
    function _opsInCurrentWindow(address wallet) internal view returns (uint32) {
        PoolActivity storage act = _activity[wallet];
        if (act.windowStart == 0) return 0;
        if (block.timestamp >= uint256(act.windowStart) + uint256(activityWindow)) return 0;
        return act.opCount;
    }

    /// @dev USD-8 already recorded in the current 1-hour window (0 if elapsed / never started).
    function _usdInCurrentWindow(address wallet) internal view returns (uint256) {
        PoolActivity storage act = _activity[wallet];
        if (act.windowStart == 0) return 0;
        if (block.timestamp >= uint256(act.windowStart) + uint256(activityWindow)) return 0;
        return act.volumeUsd;
    }

    /// @dev USD-8 already recorded in the current 24-hour Floor C window (0 if elapsed / never started).
    function _usdInDailyWindow(address wallet) internal view returns (uint256) {
        DailyActivity storage daily = _daily[wallet];
        if (daily.windowStart == 0) return 0;
        if (block.timestamp >= uint256(daily.windowStart) + uint256(dailyWindow)) return 0;
        return daily.volumeUsd;
    }

    // ── Hook for AmlHookLogic's USD quoting (avoids circular dependency) ─────

    /// @dev Abstract stub — implemented in AmlHookLogic. Activity needs quoting for `_recordActivity`
    ///      but the Chainlink feed logic lives in the leaf. Overridden once; never called externally.
    function _tryQuoteUsdRaw(address token, uint256 amount)
        internal
        view
        virtual
        returns (uint256 usd, bytes32 quoteError);

    // ── Private helpers ───────────────────────────────────────────────────────

    /// @dev Add `usd` to the 24-hour Floor C accumulator (reset when the day elapsed).
    function _recordDailyUsd(address wallet, uint256 usd) private {
        DailyActivity storage daily = _daily[wallet];
        if (daily.windowStart == 0 || block.timestamp >= uint256(daily.windowStart) + uint256(dailyWindow)) {
            daily.windowStart = uint64(block.timestamp);
            daily.volumeUsd = 0;
        }
        if (usd == type(uint256).max) {
            daily.volumeUsd = type(uint256).max;
        } else if (daily.volumeUsd != type(uint256).max) {
            daily.volumeUsd += usd;
        }
    }

    /// @dev Specified-currency volume still inside the 1-hour Floor B window.
    function _volumeInCurrentWindow(address wallet, address token) private view returns (uint256) {
        PoolActivity storage act = _activity[wallet];
        if (act.windowStart == 0) return 0;
        if (block.timestamp >= uint256(act.windowStart) + uint256(activityWindow)) return 0;
        TokenVolume storage vol = _windowVolume[wallet][token];
        if (vol.epoch != act.epoch) return 0;
        return vol.amount;
    }
}
