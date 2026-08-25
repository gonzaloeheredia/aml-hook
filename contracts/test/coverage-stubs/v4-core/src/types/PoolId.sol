// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Coverage-only stand-in. Production uses Uniswap `v4-core` `PoolId`.
///      `forge coverage` remaps `v4-core/` here so nested `lib/v4-core` (and `Pool.sol`)
///      never enter the `--ir-minimum` compile. SwapCache only needs the user type.
type PoolId is bytes32;
