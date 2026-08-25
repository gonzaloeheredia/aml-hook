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

/// @title Uniswap v4 swap currency / size helpers for the AML hook callbacks.
library SwapCurrencies {
    using PoolIdLibrary for PoolKey;

    function abs(int256 amount) internal pure returns (uint256) {
        return amount < 0 ? uint256(-amount) : uint256(amount);
    }

    /// @dev Input currency — Mitigation D baseline token.
    function inputToken(PoolKey calldata key, SwapParams calldata params) internal pure returns (address) {
        Currency c = params.zeroForOne ? key.currency0 : key.currency1;
        return Currency.unwrap(c);
    }

    /// @dev Currency of `amountSpecified`: input on exact-in, output on exact-out.
    function specifiedToken(PoolKey calldata key, SwapParams calldata params) internal pure returns (address) {
        bool exactIn = params.amountSpecified < 0;
        Currency c = exactIn
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);
        return Currency.unwrap(c);
    }

    /// @dev Specified amount vs active-tick virtual reserve (Floors A/B extra).
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

    /// @dev Settled size of the specified currency after the swap (native units).
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
