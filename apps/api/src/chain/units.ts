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
