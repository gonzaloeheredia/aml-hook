import type { Wallet, WalletId } from "../src/types.js";

export function demoWallet(
  id: WalletId,
  overrides: Partial<Wallet> = {},
): Wallet {
  return {
    id,
    accountLabel: `Account ${id}`,
    role: "test",
    address: `0x${id.padStart(40, "0")}`,
    usdc: 10_000,
    eth: 1,
    hopDistance: null,
    originId: null,
    exploitConfirmed: false,
    neverScored: false,
    ...overrides,
  };
}

export function seedDemoWallets(): Record<WalletId, Wallet> {
  return {
    A: demoWallet("A", {
      exploitConfirmed: true,
      hopDistance: 0,
      originId: "A",
      usdc: 10_000_000,
    }),
    B: demoWallet("B", { usdc: 25_000 }),
    C: demoWallet("C", { usdc: 50_000 }),
    D: demoWallet("D", { usdc: 5_000 }),
    E: demoWallet("E", { neverScored: true, usdc: 40_000 }),
  };
}
