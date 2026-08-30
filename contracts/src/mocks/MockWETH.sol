// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ETH stand-in (18 decimals, like WETH).
/// @dev Anyone can `mint`. Constructor seeds the deployer with 1_000_000 ETH.
///      Priced at $1,000 via the ETH/USD feed bound at deploy — not native Sepolia ETH.
contract MockWETH is ERC20 {
    constructor() ERC20("Mock ETH", "ETH") {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
