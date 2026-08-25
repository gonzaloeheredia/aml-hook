// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolImpact} from "./PoolImpact.sol";

/// @title SwapCurrencies — Uniswap v4 swap currency and size derivation helpers
/// @notice Utility functions used by the AML hook to derive token addresses and amounts from
///         the Uniswap v4 `PoolKey` and `SwapParams` structs.
library SwapCurrencies {
    using PoolIdLibrary for PoolKey;

    /// @notice Absolute value of a signed integer (safe for the int256 min is not used in v4 params).
    function abs(int256 amount) internal pure returns (uint256) {
        return amount < 0 ? uint256(-amount) : uint256(amount);
    }

    /// @notice The token flowing into the pool from the swapper (Mitigation D baseline token).
    /// @dev zeroForOne → currency0; else → currency1.
    function inputToken(PoolKey calldata key, SwapParams calldata params) internal pure returns (address) {
        Currency c = params.zeroForOne ? key.currency0 : key.currency1;
        return Currency.unwrap(c);
    }

    /// @notice The currency of `amountSpecified`: input token on exact-in, output token on exact-out.
    /// @dev Used as the volume token for USD accumulation and FX caching.
    function specifiedToken(PoolKey calldata key, SwapParams calldata params) internal pure returns (address) {
        bool exactIn = params.amountSpecified < 0;
        Currency c = exactIn
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);
        return Currency.unwrap(c);
    }

    /// @notice Pool-impact of this swap in bps relative to the active-tick virtual reserve.
    /// @dev Used by Floors A/B extra (unscored pool-drain and stale + pool-drain hardening).
    ///      Virtual reserve is computed from `sqrtPriceX96` and `liquidity` via `PoolImpact`.
    function poolImpactBps(IPoolManager poolManager, PoolKey calldata key, SwapParams calldata params)
        internal
        view
        returns (uint256)
    {
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, key.toId());
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsToken0 = exactIn ? params.zeroForOne : !params.zeroForOne;
        uint256 reserve = PoolImpact.virtualReserve(liquidity, sqrtPriceX96, specifiedIsToken0);
        return PoolImpact.impactBps(abs(params.amountSpecified), reserve);
    }

    /// @notice Native-unit settled amount of the specified currency after the swap.
    /// @dev Read from `delta` in `afterSwap`; used to record the actual volume (not the requested amount).
    function settledSpecified(PoolKey calldata, SwapParams calldata params, BalanceDelta delta)
        internal
        pure
        returns (uint256)
    {
        bool exactIn = params.amountSpecified < 0;
        bool useToken0 = exactIn ? params.zeroForOne : !params.zeroForOne;
        int256 settled = useToken0 ? delta.amount0() : delta.amount1();
        return abs(settled);
    }
}
