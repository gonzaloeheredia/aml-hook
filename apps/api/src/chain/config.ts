/**
 * Addresses and RPC for the local Anvil stack.
 * Prefers apps/api/.env.local (sync-deployment), then contracts/deployments/31337.json.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Address, Hex } from "viem";
import { ATTESTOR_KEY, KEEPER_KEY } from "./accounts.js";
import { ChainUnavailableError } from "./errors.js";

export type ChainConfig = {
  rpcUrl: string;
  chainId: number;
  hook: Address;
  oracle: Address;
  sanctionRegistry: Address;
  escrow: Address;
  feeToken: Address;
  usdFeed: Address;
  ethUsdFeed: Address;
  keeperKey: Hex;
  attestorKey: Hex;
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
  usdFeed?: string;
  ethUsdFeed?: string;
  complianceReserve?: string;
  ComplianceTreasury?: string;
  lpCompensationFund?: string;
};

function readDeployment(): DeploymentJson | null {
  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    join(here, "../../../../contracts/deployments/31337.json"),
    join(process.cwd(), "../../contracts/deployments/31337.json"),
    join(process.cwd(), "contracts/deployments/31337.json"),
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

let cached: ChainConfig | null = null;

/**
 * Resolve the Anvil stack config. Throws ChainUnavailableError if the hook address is missing.
 */
export function getChainConfig(): ChainConfig {
  if (cached) return cached;
  const d = readDeployment();
  const rpcUrl =
    process.env.ORACLE_RPC_URL?.trim() || "http://127.0.0.1:8545";
  const hook = addr("AML_HOOK_ADDRESS", d?.AmlHook);
  const oracle = addr("COMPLIANCE_ORACLE_ADDRESS", d?.ComplianceOracle);
  const escrow = addr("FEE_ESCROW_ADDRESS", d?.FeeEscrow);
  const feeToken = addr("FEE_TOKEN_ADDRESS", d?.feeToken);
  if (!hook || !oracle || !escrow || !feeToken) {
    throw new ChainUnavailableError();
  }
  let keeperKey = (process.env.KEEPER_PRIVATE_KEY ?? KEEPER_KEY).trim() as Hex;
  if (!keeperKey.startsWith("0x")) keeperKey = `0x${keeperKey}` as Hex;
  let attestorKey = (process.env.ATTESTOR_PRIVATE_KEY ?? ATTESTOR_KEY).trim() as Hex;
  if (!attestorKey.startsWith("0x")) attestorKey = `0x${attestorKey}` as Hex;

  cached = {
    rpcUrl,
    chainId: Number(process.env.ORACLE_CHAIN_ID ?? d?.chainId ?? 31337),
    hook,
    oracle,
    sanctionRegistry: addr("SANCTION_REGISTRY_ADDRESS", d?.SanctionRegistry) ??
      ("0x0000000000000000000000000000000000000000" as Address),
    escrow,
    feeToken,
    usdFeed: addr("USD_FEED_ADDRESS", d?.usdFeed) ??
      ("0x0000000000000000000000000000000000000000" as Address),
    ethUsdFeed: addr("ETH_USD_FEED_ADDRESS", d?.ethUsdFeed) ??
      ("0x0000000000000000000000000000000000000000" as Address),
    keeperKey,
    attestorKey,
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
