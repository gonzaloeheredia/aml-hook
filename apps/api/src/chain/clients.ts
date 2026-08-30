/**
 * Shared viem clients for Anvil or Sepolia.
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  type Account,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { anvil, sepolia } from "viem/chains";
import { getChainConfig, isLocalAnvil, SEPOLIA_CHAIN_ID } from "./config.js";
import { ChainUnavailableError } from "./errors.js";

function chain() {
  const cfg = getChainConfig();
  const base = cfg.chainId === SEPOLIA_CHAIN_ID ? sepolia : anvil;
  return { ...base, id: cfg.chainId };
}

export function publicClient() {
  const cfg = getChainConfig();
  return createPublicClient({
    chain: chain(),
    transport: http(cfg.rpcUrl),
  });
}

export function walletClient(privateKey: Hex) {
  const cfg = getChainConfig();
  const account = privateKeyToAccount(privateKey);
  return {
    account,
    client: createWalletClient({
      account,
      chain: chain(),
      transport: http(cfg.rpcUrl),
    }),
  };
}

export function keeperWallet() {
  return walletClient(getChainConfig().keeperKey);
}

export function registryWallet() {
  return walletClient(getChainConfig().registryKeeperKey);
}

export function governorWallet() {
  return walletClient(getChainConfig().hookGovernorKey);
}

/**
 * Ping the configured RPC. Throws ChainUnavailableError if it is down or the hook has no code.
 */
export async function requireChain(): Promise<void> {
  try {
    const cfg = getChainConfig();
    const client = publicClient();
    await client.getChainId();
    const code = await client.getCode({ address: cfg.hook });
    if (!code || code === "0x") {
      throw new ChainUnavailableError();
    }
  } catch (err) {
    if (err instanceof ChainUnavailableError) throw err;
    throw new ChainUnavailableError();
  }
}

export async function chainHealth(): Promise<{
  ok: boolean;
  rpcUrl: string | null;
  hook: string | null;
  reason?: string;
}> {
  try {
    await requireChain();
    const cfg = getChainConfig();
    return { ok: true, rpcUrl: cfg.rpcUrl, hook: cfg.hook };
  } catch (err) {
    return {
      ok: false,
      rpcUrl: process.env.ORACLE_RPC_URL ?? "http://127.0.0.1:8545",
      hook: null,
      reason: err instanceof Error ? err.message : String(err),
    };
  }
}

export async function anvilRpc(method: string, params: unknown[] = []): Promise<unknown> {
  if (!isLocalAnvil()) {
    throw new Error(`${method} is Anvil-only and cannot run on chain ${getChainConfig().chainId}.`);
  }
  const cfg = getChainConfig();
  const res = await fetch(cfg.rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const body = (await res.json()) as { result?: unknown; error?: { message?: string } };
  if (body.error) {
    throw new ChainUnavailableError(body.error.message ?? method);
  }
  return body.result;
}

export type { Account };
