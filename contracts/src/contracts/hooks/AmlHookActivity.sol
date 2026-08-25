// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AmlHookGovernance} from "./AmlHookGovernance.sol";
import {IERC20Minimal} from "../../interfaces/external/IERC20Minimal.sol";
import {OracleQuote} from "../../libraries/OracleQuote.sol";

/// @title Floor B/C accumulators and Mitigation D baseline. No setters.
abstract contract AmlHookActivity is AmlHookGovernance {
    struct PoolActivity {
        uint64 windowStart;
        uint32 opCount;
        uint64 lastSwapAt;
        uint32 epoch;
        uint256 volumeUsd;
    }

    struct DailyActivity {
        uint64 windowStart;
        uint256 volumeUsd;
    }

    struct TokenVolume {
        uint32 epoch;
        uint256 amount;
    }

    mapping(address => PoolActivity) internal _activity;
    mapping(address => DailyActivity) internal _daily;
    mapping(address => mapping(address => TokenVolume)) internal _windowVolume;
    mapping(address => mapping(address => uint256)) public lastKnownBalance;
    mapping(address => mapping(address => uint256)) public lastKnownBalanceTimestamp;

    function poolActivity(address wallet) external view returns (uint64 windowStart, uint32 opCount, uint64 lastSwapAt) {
        PoolActivity storage act = _activity[wallet];
        return (act.windowStart, act.opCount, act.lastSwapAt);
    }

    function windowVolume(address wallet, address token) external view returns (uint256) {
        return _volumeInCurrentWindow(wallet, token);
    }

    function windowVolumeUsd(address wallet) external view returns (uint256) {
        return _usdInCurrentWindow(wallet);
    }

    function dailyVolumeUsd(address wallet) external view returns (uint256) {
        return _usdInDailyWindow(wallet);
    }

    function _recordActivity(address wallet) internal {
        _recordActivity(wallet, address(0), 0);
    }

    function _recordActivity(address wallet, address token, uint256 amount) internal {
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

        (uint256 usd, bytes32 quoteError) = OracleQuote.tryQuote(priceFeeds, priceStalenessThreshold, token, amount);
        if (quoteError != bytes32(0)) {
            act.volumeUsd = type(uint256).max;
            _recordDailyUsd(wallet, type(uint256).max);
        } else if (act.volumeUsd != type(uint256).max) {
            act.volumeUsd += usd;
            _recordDailyUsd(wallet, usd);
        }
    }

    function _updateKnownBalance(address wallet, address token, bool inflowTriggered) internal {
        if (inflowTriggered) return;
        if (token == address(0) || token.code.length == 0) return;
        uint256 lastWriteTs = lastKnownBalanceTimestamp[wallet][token];
        if (lastWriteTs != 0 && block.timestamp < lastWriteTs + uint256(minBaselineInterval)) return;
        lastKnownBalance[wallet][token] = IERC20Minimal(token).balanceOf(wallet);
        lastKnownBalanceTimestamp[wallet][token] = block.timestamp;
    }

    function _opsInCurrentWindow(address wallet) internal view returns (uint32) {
        PoolActivity storage act = _activity[wallet];
        if (act.windowStart == 0) return 0;
        if (block.timestamp >= uint256(act.windowStart) + uint256(activityWindow)) return 0;
        return act.opCount;
    }

    function _usdInCurrentWindow(address wallet) internal view returns (uint256) {
        PoolActivity storage act = _activity[wallet];
        if (act.windowStart == 0) return 0;
        if (block.timestamp >= uint256(act.windowStart) + uint256(activityWindow)) return 0;
        return act.volumeUsd;
    }

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

    function _volumeInCurrentWindow(address wallet, address token) private view returns (uint256) {
        PoolActivity storage act = _activity[wallet];
        if (act.windowStart == 0) return 0;
        if (block.timestamp >= uint256(act.windowStart) + uint256(activityWindow)) return 0;
        TokenVolume storage vol = _windowVolume[wallet][token];
        if (vol.epoch != act.epoch) return 0;
        return vol.amount;
    }
}
