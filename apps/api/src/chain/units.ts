/**
 * Converts a nominal USDC amount to on-chain wei units using 18 decimals.
 * This matches MockFeeToken (18 dec) used in the demo — NOT real USDC (6 dec).
 * Any integration with real USDC must pass the actual token decimal count instead.
 */
export function usdcToWei(usdc: number): bigint {
  return BigInt(Math.round(usdc)) * 10n ** 18n;
}

/**
 * Converts on-chain wei units back to a nominal USDC amount assuming 18 decimals.
 * Matches MockFeeToken (18 dec) — NOT real USDC (6 dec).
 */
export function weiToUsdc(wei: bigint): number {
  return Number(wei / 10n ** 18n);
}
