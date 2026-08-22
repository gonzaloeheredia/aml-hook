export function usdcToWei(usdc: number): bigint {
  return BigInt(Math.round(usdc)) * 10n ** 18n;
}

export function weiToUsdc(wei: bigint): number {
  return Number(wei / 10n ** 18n);
}
