/**
 * Local Anvil identities for the A–D guided demo.
 * Wallet E is the MetaMask EOA bound at runtime (no Foundry key).
 * Keys stay on the API. The browser never sees them.
 */

import { zeroAddress, type Address, type Hex } from "viem";
import type { WalletId } from "../types.js";

/** Retired Anvil #5 label. Never treat this as Wallet E. */
const RETIRED_ANVIL_E = "0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc";

/** Anvil #0: deployer / oracle keeper / hook governor / FeeEscrow owner. */
export const KEEPER_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex;
export const KEEPER_ADDRESS =
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as Address;

/** Anvil #9: distinct attestor (Deploy local default). */
export const ATTESTOR_KEY =
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6" as Hex;
export const ATTESTOR_ADDRESS =
  "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720" as Address;

export type DemoAccount = {
  address: Address;
  key?: Hex;
  usdc: number;
  eth: number;
};

export const DEMO_WALLETS: Record<WalletId, DemoAccount> = {
  A: {
    address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    key: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    usdc: 10_000_000,
    eth: 5,
  },
  B: {
    address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    key: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    usdc: 25_000,
    eth: 4,
  },
  C: {
    address: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    key: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141c007c7",
    usdc: 50_000,
    eth: 8,
  },
  D: {
    address: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
    key: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
    usdc: 5_000,
    eth: 2,
  },
  E: {
    address: zeroAddress,
    usdc: 0,
    eth: 0,
  },
};

/** True when E has a live Sepolia EOA (MetaMask), not the unbound / retired Anvil row. */
export function isBoundWalletE(address: string | undefined): boolean {
  if (!address || address.length !== 42) return false;
  const lower = address.toLowerCase();
  return lower !== zeroAddress.toLowerCase() && lower !== RETIRED_ANVIL_E;
}

/** Where a demo "swap" sends USDC. Not a PoolManager. */
export const POOL_SINK =
  "0x000000000000000000000000000000000000Dd01" as Address;

export const WALLET_IDS = Object.keys(DEMO_WALLETS) as WalletId[];

export function hasSigner(id: WalletId): boolean {
  return Boolean(DEMO_WALLETS[id].key);
}

export function idFromAddress(address: string): WalletId | null {
  const lower = address.toLowerCase();
  if (lower === zeroAddress || lower === RETIRED_ANVIL_E) return null;
  for (const id of WALLET_IDS) {
    if (id === "E") continue;
    if (DEMO_WALLETS[id].address.toLowerCase() === lower) return id;
  }
  return null;
}
