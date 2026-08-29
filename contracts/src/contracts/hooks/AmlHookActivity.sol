// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookGovernanceBase} from "./AmlHookGovernanceBase.sol";
import {IERC20Minimal} from "../../interfaces/external/IERC20Minimal.sol";
import {OracleQuote} from "../../libraries/OracleQuote.sol";

/// @title AmlHookActivity — rolling-window accumulators for Floor B/C and Mitigation D baseline
/// @notice Tracks per-wallet operation counts, USD volume, and token balances.
///         Swap Floor C uses `_daily`. LP Floor C uses `_lpDaily` (adds only; never mixed).
///         No compliance decisions here — all reads are consumed by `AmlHookLogic`.
abstract contract AmlHookActivity is AmlHookGovernanceBase {
    /// @dev Rolling `activityWindow` accumulator per wallet.
    struct PoolActivity {
        uint64 windowStart;  // timestamp when the current window opened
        uint32 opCount;      // swaps recorded in the current window
        uint64 lastSwapAt;   // block timestamp of the most recent recorded swap
        uint32 epoch;        // incremented on window rollover; used to invalidate TokenVolume entries
        uint256 volumeUsd;   // 8-decimal USD volume in the current window (type(uint256).max = overflow)
    }

    /// @dev Rolling `dailyWindow` USD accumulator per wallet.
    struct DailyActivity {
        uint64 windowStart;  // timestamp when the current daily window opened
        uint256 volumeUsd;   // 8-decimal USD volume in the current daily window
    }

    /// @dev Per-wallet per-token native-unit accumulator, epoch-gated so stale entries are free to ignore.
    struct TokenVolume {
        uint32 epoch;    // must match `_activity[wallet].epoch` to be considered current
        uint256 amount;  // token-native units accumulated in the current window
    }

    /// @dev Rolling activity snapshot per wallet (operation count, volume, timestamps).
    mapping(address => PoolActivity) internal _activity;
    /// @dev Daily USD accumulator per wallet (swaps — Floor C).
    mapping(address => DailyActivity) internal _daily;
    /// @dev Daily USD of LP adds per wallet (LP Floor C analog). Never mixed with swap C.
    mapping(address => DailyActivity) internal _lpDaily;
    /// @dev Native-unit volume per wallet per token in the current epoch window.
    mapping(address => mapping(address => TokenVolume)) internal _windowVolume;

    /// @notice Last-seen ERC-20 balance per wallet per token (Mitigation D baseline).
    mapping(address => mapping(address => uint256)) public lastKnownBalance;
    /// @notice Block timestamp of the last `lastKnownBalance` write per wallet per token.
    mapping(address => mapping(address => uint256)) public lastKnownBalanceTimestamp;

    /// @notice Returns the current rolling-window activity snapshot for `wallet`.
    /// @return windowStart Timestamp when the current window opened (0 if never recorded).
    /// @return opCount     Swap count in the current window.
    /// @return lastSwapAt  Timestamp of the most recent recorded swap.
    function poolActivity(address wallet) external view returns (uint64 windowStart, uint32 opCount, uint64 lastSwapAt) {
        PoolActivity storage act = _activity[wallet];
        return (act.windowStart, act.opCount, act.lastSwapAt);
    }

    /// @notice Native-unit volume for `wallet` and `token` in the current activity window.
    function windowVolume(address wallet, address token) external view returns (uint256) {
        return _volumeInCurrentWindow(wallet, token);
    }

    /// @notice 8-decimal USD volume for `wallet` in the current activity window.
    ///         Returns `type(uint256).max` when the window had a price-quote failure.
    function windowVolumeUsd(address wallet) external view returns (uint256) {
        return _usdInCurrentWindow(wallet);
    }

    /// @notice 8-decimal USD volume for `wallet` in the current daily window.
    ///         Returns `type(uint256).max` when the window had a price-quote failure.
    function dailyVolumeUsd(address wallet) external view returns (uint256) {
        return _usdInDailyWindow(wallet);
    }

    /// @notice 8-decimal USD of LP adds in the current daily window (LP Floor C).
    function lpDailyVolumeUsd(address wallet) external view returns (uint256) {
        return _usdInLpDailyWindow(wallet);
    }

    function _recordActivity(address wallet) internal {
        _recordActivity(wallet, address(0), 0, OracleQuote.Fx(0, 0, 0, 0, false, false));
    }

    function _recordActivity(address wallet, address token, uint256 amount) internal {
        _recordActivity(wallet, token, amount, OracleQuote.Fx(0, 0, 0, 0, false, false));
    }

    function _recordActivity(address wallet, address token, uint256 amount, OracleQuote.Fx memory fx) internal {
        PoolActivity storage act = _activity[wallet];
        bool windowElapsed = act.windowStart != 0 && block.timestamp >= uint256(act.windowStart) + uint256(activityWindow);

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

        if (fx.price == 0) {
            bytes32 quoteError;
            (fx, quoteError) =
                OracleQuote.resolve(priceFeeds, lastFx, priceStalenessThreshold, MAX_PRICE_STALENESS, token);
            if (quoteError != bytes32(0)) {
                act.volumeUsd = type(uint256).max;
                _recordDailyUsd(wallet, type(uint256).max);
                return;
            }
            OracleQuote.commit(lastFx, token, fx);
        }

        uint256 usd = OracleQuote.toUsd(fx, amount);
        if (act.volumeUsd != type(uint256).max) {
            act.volumeUsd += usd;
            _recordDailyUsd(wallet, usd);
        }
    }

    /// @dev Write the current ERC-20 balance of `wallet` for `token` as the Mitigation D baseline.
    ///      Skipped when `inflowTriggered` (the heuristic already fired — resetting the baseline
    ///      would hide the inflow from future evaluations until the oracle catches up), when the
    ///      token is not an ERC-20 contract, or when less than `minBaselineInterval` has elapsed.
    function _updateKnownBalance(address wallet, address token, bool inflowTriggered) internal {
        if (inflowTriggered) return;
        if (token == address(0) || token.code.length == 0) return;
        uint256 lastWriteTs = lastKnownBalanceTimestamp[wallet][token];
        if (lastWriteTs != 0 && block.timestamp < lastWriteTs + uint256(minBaselineInterval)) return;
        lastKnownBalance[wallet][token] = IERC20Minimal(token).balanceOf(wallet);
        lastKnownBalanceTimestamp[wallet][token] = block.timestamp;
    }

    /// @dev Returns 0 when the window has not been opened yet or has elapsed.
    function _opsInCurrentWindow(address wallet) internal view returns (uint32) {
        PoolActivity storage act = _activity[wallet];
        if (act.windowStart == 0) return 0;
        if (block.timestamp >= uint256(act.windowStart) + uint256(activityWindow)) return 0;
        return act.opCount;
    }

    /// @dev Returns 0 when no window is open or it has elapsed. Returns `type(uint256).max` on overflow.
    function _usdInCurrentWindow(address wallet) internal view returns (uint256) {
        PoolActivity storage act = _activity[wallet];
        if (act.windowStart == 0) return 0;
        if (block.timestamp >= uint256(act.windowStart) + uint256(activityWindow)) return 0;
        return act.volumeUsd;
    }

    /// @dev Returns 0 when no daily window is open or it has elapsed. Returns `type(uint256).max` on overflow.
    function _usdInDailyWindow(address wallet) internal view returns (uint256) {
        DailyActivity storage daily = _daily[wallet];
        if (daily.windowStart == 0) return 0;
        if (block.timestamp >= uint256(daily.windowStart) + uint256(dailyWindow)) return 0;
        return daily.volumeUsd;
    }

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

    /// @dev LP Floor C: record this add's USD into a dedicated daily window.
    function _recordLpDailyUsd(address wallet, uint256 usd) internal {
        DailyActivity storage daily = _lpDaily[wallet];
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

    function _usdInLpDailyWindow(address wallet) internal view returns (uint256) {
        DailyActivity storage daily = _lpDaily[wallet];
        if (daily.windowStart == 0) return 0;
        if (block.timestamp >= uint256(daily.windowStart) + uint256(dailyWindow)) return 0;
        return daily.volumeUsd;
    }

    function _volumeInCurrentWindow(address wallet, address token) private view returns (uint256) {
        PoolActivity storage act = _activity[wallet];
        if (act.windowStart == 0) return 0;
        if (block.timestamp >= uint256(act.windowStart) + uint256(activityWindow)) return 0;
        TokenVolume storage vol = _windowVolume[wallet][token];
        if (vol.epoch != act.epoch) return 0;
        return vol.amount;
    }
}
