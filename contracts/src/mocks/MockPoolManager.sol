// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice MOCK — placeholder PoolManager for local Anvil deploys only.
/// @dev NOT a Uniswap v4 PoolManager: no swap/liquidity logic.
///      Used so DeployAmlStack can wire AmlHook (`onlyPoolManager` + CREATE2 flags).
///      Production / live pool swaps require a real IPoolManager (set POOL_MANAGER env).
contract MockPoolManager {
    // Intentionally empty — address stand-in for AmlHook constructor.
}
