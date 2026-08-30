/**
 * Converts a nominal USDC amount to on-chain units using 6 decimals.
 * Matches MockUSDC and Circle USDC.
 */
export function usdcToWei(usdc: number): bigint {
  return BigInt(Math.round(usdc)) * 10n ** 6n;
}

/**
 * Converts on-chain USDC units back to a nominal amount assuming 6 decimals.
 */
export function weiToUsdc(wei: bigint): number {
  return Number(wei / 10n ** 6n);
}

/**
 * Converts a nominal ETH amount to MockWETH units (18 decimals).
 */
export function ethToWei(eth: number): bigint {
  return BigInt(Math.round(eth * 1e6)) * 10n ** 12n;
}

/**
 * Converts MockWETH units back to a nominal ETH amount (18 decimals).
 */
export function weiToEth(wei: bigint): number {
  return Number(wei / 10n ** 12n) / 1e6;
}
