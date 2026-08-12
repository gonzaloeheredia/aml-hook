// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal mintable ERC-20 for inflow-heuristic tests.
contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }
}
