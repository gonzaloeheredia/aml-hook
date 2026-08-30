/**
 * Addresses and RPC for Anvil (31337) or Sepolia (11155111).
 * Prefers process env, then contracts/deployments/<chainId>.json.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Address, Hex } from "viem";
import { ATTESTOR_KEY, KEEPER_KEY } from "./accounts.js";
import { ChainUnavailableError } from "./errors.js";

export const ANVIL_CHAIN_ID = 31337;
export const SEPOLIA_CHAIN_ID = 11155111;

export type ChainConfig = {
  rpcUrl: string;
  chainId: number;
  hook: Address;
  oracle: Address;
  sanctionRegistry: Address;
  escrow: Address;
  feeToken: Address;
  wethToken: Address;
  usdFeed: Address;
  ethUsdFeed: Address;
  poolManager: Address;
  keeperKey: Hex;
  attestorKey: Hex;
  registryKeeperKey: Hex;
  hookGovernorKey: Hex;
  complianceReserve: Address;
  lpCompensationFund: Address;
};

type DeploymentJson = {
  chainId?: number;
  AmlHook?: string;
  SanctionRegistry?: string;
  ComplianceOracle?: string;
  FeeEscrow?: string;
  feeToken?: string;
  wethToken?: string;
  usdFeed?: string;
  ethUsdFeed?: string;
  poolManager?: string;
  complianceReserve?: string;
  ComplianceTreasury?: string;
  lpCompensationFund?: string;
};

function envChainId(): number {
  const n = Number(process.env.ORACLE_CHAIN_ID);
  return Number.isFinite(n) && n > 0 ? n : ANVIL_CHAIN_ID;
}

function readDeployment(chainId: number): DeploymentJson | null {
  const file = `${chainId}.json`;
  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    join(here, `../../../../contracts/deployments/${file}`),
    join(process.cwd(), `../../contracts/deployments/${file}`),
    join(process.cwd(), `contracts/deployments/${file}`),
  ];
  for (const path of candidates) {
    if (!existsSync(path)) continue;
    try {
      return JSON.parse(readFileSync(path, "utf8")) as DeploymentJson;
    } catch {
      return null;
    }
  }
  return null;
}

function addr(envName: string, fallback?: string): Address | undefined {
  const v = (process.env[envName] ?? fallback ?? "").trim();
  if (!v || !v.startsWith("0x")) return undefined;
  return v as Address;
}

function hexKey(envName: string, fallback?: string): Hex | undefined {
  let v = (process.env[envName] ?? fallback ?? "").trim();
  if (!v) return undefined;
  if (!v.startsWith("0x")) v = `0x${v}`;
  if (v.length !== 66) return undefined;
  return v as Hex;
}

let cached: ChainConfig | null = null;

export function isLocalAnvil(chainId = envChainId()): boolean {
  return chainId === ANVIL_CHAIN_ID;
}

/**
 * Resolve stack config. Throws ChainUnavailableError if the hook address is missing.
 */
export function getChainConfig(): ChainConfig {
  if (cached) return cached;
  const chainId = envChainId();
  const d = readDeployment(chainId);
  const rpcUrl =
    process.env.ORACLE_RPC_URL?.trim() ||
    (isLocalAnvil(chainId) ? "http://127.0.0.1:8545" : "");
  if (!rpcUrl) {
    throw new Error("ORACLE_RPC_URL is required when ORACLE_CHAIN_ID is not 31337.");
  }
  const hook = addr("AML_HOOK_ADDRESS", d?.AmlHook);
  const oracle = addr("COMPLIANCE_ORACLE_ADDRESS", d?.ComplianceOracle);
  const escrow = addr("FEE_ESCROW_ADDRESS", d?.FeeEscrow);
  const feeToken = addr("FEE_TOKEN_ADDRESS", d?.feeToken);
  if (!hook || !oracle || !escrow || !feeToken) {
    throw new ChainUnavailableError();
  }

  const anvil = isLocalAnvil(chainId);
  const keeperKey = hexKey("KEEPER_PRIVATE_KEY", anvil ? KEEPER_KEY : undefined);
  const attestorKey = hexKey("ATTESTOR_PRIVATE_KEY", anvil ? ATTESTOR_KEY : undefined);
  if (!keeperKey || !attestorKey) {
    throw new Error(
      "KEEPER_PRIVATE_KEY and ATTESTOR_PRIVATE_KEY are required on a live chain. Do not use Anvil defaults.",
    );
  }

  cached = {
    rpcUrl,
    chainId: Number(process.env.ORACLE_CHAIN_ID ?? d?.chainId ?? chainId),
    hook,
    oracle,
    sanctionRegistry: addr("SANCTION_REGISTRY_ADDRESS", d?.SanctionRegistry) ??
      ("0x0000000000000000000000000000000000000000" as Address),
    escrow,
    feeToken,
    wethToken: addr("WETH_TOKEN_ADDRESS", d?.wethToken) ??
      ("0x0000000000000000000000000000000000000000" as Address),
    usdFeed: addr("USD_FEED_ADDRESS", d?.usdFeed) ??
      ("0x0000000000000000000000000000000000000000" as Address),
    ethUsdFeed: addr("ETH_USD_FEED_ADDRESS", d?.ethUsdFeed) ??
      ("0x0000000000000000000000000000000000000000" as Address),
    poolManager: addr("POOL_MANAGER_ADDRESS", d?.poolManager) ??
      ("0x0000000000000000000000000000000000000000" as Address),
    keeperKey,
    attestorKey,
    registryKeeperKey: hexKey("REGISTRY_KEEPER_PRIVATE_KEY") ?? keeperKey,
    hookGovernorKey: hexKey("HOOK_GOVERNOR_PRIVATE_KEY") ?? keeperKey,
    complianceReserve: addr("COMPLIANCE_RESERVE", d?.ComplianceTreasury ?? d?.complianceReserve) ??
      ("0x0000000000000000000000000000000000000000" as Address),
    lpCompensationFund: addr("LP_COMPENSATION_FUND", d?.lpCompensationFund) ??
      ("0x0000000000000000000000000000000000000000" as Address),
  };
  return cached;
}

/** Drop cached addresses after a re-deploy without restarting if env is rewritten. */
export function clearChainConfig(): void {
  cached = null;
}
