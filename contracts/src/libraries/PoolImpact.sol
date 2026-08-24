// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title Active-tick virtual reserve vs swap size (Floor A pool-impact).
/// @notice Uniswap v4 has no v2-style reserves. This uses in-range liquidity × price.
library PoolImpact {
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant MAX_BPS = 10_000;

    /// @notice Token0 or token1 virtual reserve implied by current active liquidity.
    function virtualReserve(uint128 liquidity, uint160 sqrtPriceX96, bool token0)
        internal
        pure
        returns (uint256)
    {
        if (liquidity == 0 || sqrtPriceX96 == 0) return 0;
        if (token0) {
            return FullMath.mulDiv(uint256(liquidity), Q96, sqrtPriceX96);
        }
        return FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, Q96);
    }

    /// @notice `amount / reserve` in bps, capped at 100%. Empty reserve is a full drain.
    function impactBps(uint256 amount, uint256 reserve) internal pure returns (uint256) {
        if (reserve == 0) return MAX_BPS;
        if (amount >= reserve) return MAX_BPS;
        return (amount * MAX_BPS) / reserve;
    }
}
