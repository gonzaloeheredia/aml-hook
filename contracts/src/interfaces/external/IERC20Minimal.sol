// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal ERC-20 surface used by the beforeSwap inflow heuristic.
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}
