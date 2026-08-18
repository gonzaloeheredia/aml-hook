// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Canonical Uniswap Universal Router addresses (app.uniswap.org)
/// @notice Lookup table for the routers Uniswap Labs ships in the web app.
/// @dev Addresses are chain-specific (Uniswap v4 deployments). The hook never
///      deploys these; Deploy.sol registers them via `setTrustedRouter` so
///      `IMsgSender.msgSender()` is the end-user without frontend hookData.
library UniversalRouters {
    /// @notice Universal Router used by app.uniswap.org on `chainId`, or zero if unknown.
    function appRouter(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af; // Ethereum
        if (chainId == 10) return 0x851116D9223fabED8E56C0E6b8Ad0c31d98B3507; // Optimism
        if (chainId == 56) return 0x1906c1d672b88cD1B9aC7593301cA990F94Eae07; // BNB
        if (chainId == 130) return 0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3; // Unichain
        if (chainId == 137) return 0x1095692A6237d83C6a72F3F5eFEdb9A670C49223; // Polygon
        if (chainId == 8453) return 0x6fF5693b99212Da76ad316178A184AB56D299b43; // Base
        if (chainId == 42161) return 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3; // Arbitrum
        if (chainId == 43114) return 0x94b75331AE8d42C1b61065089B7d48FE14aA73b7; // Avalanche
        if (chainId == 11155111) return 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b; // Sepolia
        if (chainId == 1301) return 0xf70536B3bcC1bD1a972dc186A2cf84cC6da6Be5D; // Unichain Sepolia
        if (chainId == 84532) return 0x492E6456D9528771018DeB9E87ef7750EF184104; // Base Sepolia
        return address(0);
    }

    /// @notice Universal Router 2.1.1 on `chainId`, or zero if unknown / same as `appRouter`.
    function appRouterV211(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA; // Ethereum
        if (chainId == 10) return 0x8B844f885672f333Bc0042cB669255f93a4C1E6b; // Optimism
        if (chainId == 56) return 0x8B844f885672f333Bc0042cB669255f93a4C1E6b; // BNB
        if (chainId == 130) return 0xFdf682F51FE81Aa4898F0AE2163d8A55c127fbC7; // Unichain
        if (chainId == 137) return 0x8B844f885672f333Bc0042cB669255f93a4C1E6b; // Polygon
        if (chainId == 8453) return 0xFdf682F51FE81Aa4898F0AE2163d8A55c127fbC7; // Base
        if (chainId == 42161) return 0x8B844f885672f333Bc0042cB669255f93a4C1E6b; // Arbitrum
        if (chainId == 43114) return 0x8B844f885672f333Bc0042cB669255f93a4C1E6b; // Avalanche
        if (chainId == 11155111) return 0x7DfD4F31be6814D2906BDE155c3e1B146EAc1468; // Sepolia
        if (chainId == 1301) return 0x8B844f885672f333Bc0042cB669255f93a4C1E6b; // Unichain Sepolia
        return address(0);
    }
}
