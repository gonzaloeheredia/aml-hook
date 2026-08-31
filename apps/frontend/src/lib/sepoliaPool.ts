/**
 * Live Sepolia v4 pool (MockUSDC → MockWETH) used by Wallet E.
 * Addresses match docs/Sepolia.md and contracts/deployments/11155111-pool.json.
 */

export const SEPOLIA_CHAIN_ID = 11_155_111;
export const SEPOLIA_CHAIN_HEX = "0xaa36a7";

export const SEPOLIA_MOCK_USDC =
  "0xa95c6057B2Bf93476590D93539dC5beB53549684" as const;
export const SEPOLIA_MOCK_WETH =
  "0x51f63BD627B0a43497E474Ffa93C1108Eb853F2a" as const;
export const SEPOLIA_HOOK =
  "0x943Af5f4aC70869b1F794FE3C8277de0f4AecfC7" as const;
export const SEPOLIA_POOL_MANAGER =
  "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543" as const;
/** Official app.uniswap.org Universal Router on Ethereum Sepolia. */
export const SEPOLIA_UNIVERSAL_ROUTER =
  "0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b" as const;
/** Canonical Permit2. */
export const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as const;

export const SEPOLIA_POOL_FEE = 8_388_608;
export const SEPOLIA_TICK_SPACING = 60;
export const USDC_DECIMALS = 6;

/** Uniswap app preloaded with this pair on Sepolia (fallback / explorer). */
export const UNISWAP_SEPOLIA_POOL_URL =
  `https://app.uniswap.org/swap?chain=sepolia` +
  `&inputCurrency=${SEPOLIA_MOCK_USDC}` +
  `&outputCurrency=${SEPOLIA_MOCK_WETH}`;
