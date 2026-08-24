// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Official Chainlink AggregatorV3 USD proxies + canonical tokens
/// @notice Lookup table so Deploy binds real ETH/USD and USDC/USD instead of MockUsdFeed.
/// @dev Proxy addresses from data.chain.link / Chainlink Data Feeds docs. Env
///      `ETH_USD_FEED` / `TOKEN_USD_FEED` override these. Anvil (31337) has none —
///      Deploy falls back to MockUsdFeed there only.
library ChainlinkFeeds {
    /// @notice ETH/USD Data Feed proxy on `chainId`, or zero if unknown.
    function ethUsd(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // Ethereum
        if (chainId == 10) return 0x13e3Ee699D1909E989722E753853AE30b17e08c5; // Optimism
        if (chainId == 56) return 0x9EF1b8c0e4F7dc8bf5715F38507545B8Bd73EA73; // BNB
        if (chainId == 130) return 0xbCE7e39f7c31278D98c4931818b7608a28798ccA; // Unichain
        if (chainId == 137) return 0xF9680D99D6C9589e2a93a78A04A279e509205945; // Polygon
        if (chainId == 8453) return 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // Base
        if (chainId == 42161) return 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Arbitrum
        if (chainId == 43114) return 0x976B3D034E162D8Bd72D6B9C989D545b90E57ac6; // Avalanche
        if (chainId == 11155111) return 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia
        if (chainId == 84532) return 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1; // Base Sepolia
        return address(0);
    }

    /// @notice USDC/USD Data Feed proxy on `chainId`, or zero if unknown.
    function usdcUsd(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // Ethereum
        if (chainId == 10) return 0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3; // Optimism
        if (chainId == 56) return 0x51597f405303C4377E36123cBc172b13269EA163; // BNB
        if (chainId == 137) return 0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7; // Polygon
        if (chainId == 8453) return 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B; // Base
        if (chainId == 42161) return 0x50834A87939A0B21b2611F69Ae7A7555d1c9Aa35; // Arbitrum
        if (chainId == 43114) return 0xF096872672f44d6ebA71458D74fe67f9A77a23D9; // Avalanche
        if (chainId == 11155111) return 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E; // Sepolia
        return address(0);
    }

    /// @notice Canonical WETH (or WETH.e) on `chainId`, or zero if unknown.
    /// @dev Bound to the ETH/USD feed so a WETH specified-currency swap quotes like native ETH.
    function weth(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        if (chainId == 10) return 0x4200000000000000000000000000000000000006;
        if (chainId == 56) return 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
        if (chainId == 130) return 0x4200000000000000000000000000000000000006;
        if (chainId == 137) return 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
        if (chainId == 8453) return 0x4200000000000000000000000000000000000006;
        if (chainId == 42161) return 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        if (chainId == 43114) return 0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB;
        if (chainId == 11155111) return 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        if (chainId == 84532) return 0x4200000000000000000000000000000000000006;
        if (chainId == 1301) return 0x4200000000000000000000000000000000000006;
        return address(0);
    }

    /// @notice Native USDC on `chainId`, or zero if unknown.
    function usdc(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        if (chainId == 10) return 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
        if (chainId == 56) return 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
        if (chainId == 130) return 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
        if (chainId == 137) return 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
        if (chainId == 8453) return 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        if (chainId == 42161) return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        if (chainId == 43114) return 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        if (chainId == 11155111) return 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        if (chainId == 84532) return 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        return address(0);
    }
}
