/**
 * Live Sepolia v4 pool (MockUSDC → MockWETH) used by Wallet E.
 * Addresses match docs/Sepolia.md and contracts/deployments/11155111-pool.json.
 */

export const SEPOLIA_MOCK_USDC =
  "0xa95c6057B2Bf93476590D93539dC5beB53549684";
export const SEPOLIA_MOCK_WETH =
  "0x51f63BD627B0a43497E474Ffa93C1108Eb853F2a";

/** Uniswap app preloaded with this pair on Sepolia. */
export const UNISWAP_SEPOLIA_POOL_URL =
  `https://app.uniswap.org/swap?chain=sepolia` +
  `&inputCurrency=${SEPOLIA_MOCK_USDC}` +
  `&outputCurrency=${SEPOLIA_MOCK_WETH}`;
