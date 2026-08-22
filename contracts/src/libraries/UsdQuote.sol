// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Convert a token amount to USD with 8 decimals (Chainlink convention).
/// @dev `usd8 = amount * price * 10^8 / (10^tokenDecimals * 10^feedDecimals)`.
library UsdQuote {
    uint8 internal constant USD_DECIMALS = 8;

    /// @notice Quote `amount` of a `tokenDecimals`-token at `price` / `feedDecimals` into USD-8.
    /// @dev Returns 0 when `price` is 0. Reverts on overflow via `Math.mulDiv`.
    function toUsd8(uint256 amount, uint8 tokenDecimals, uint256 price, uint8 feedDecimals)
        internal
        pure
        returns (uint256)
    {
        if (amount == 0 || price == 0) return 0;
        uint256 numeratorScale = 10 ** uint256(USD_DECIMALS);
        uint256 denominator = (10 ** uint256(tokenDecimals)) * (10 ** uint256(feedDecimals));
        return Math.mulDiv(amount, price * numeratorScale, denominator);
    }
}
