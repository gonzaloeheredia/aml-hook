import type { Address } from "./types.js";
import deployment31337 from "../deployments/31337.json" with { type: "json" };

export type ChainDeployment = {
  chainId: number;
  deployer: Address;
  keeper: Address;
  poolManager: Address;
  SanctionRegistry: Address;
  ComplianceOracle: Address;
  RiskPolicy: Address;
  AmlHook: Address;
};

/**
 * Returns checked-in deployment addresses for a chain.
 * Refresh via `node scripts/deploy-local.mjs` (writes 31337.json).
 */
export function getDeployment(chainId: number): ChainDeployment | null {
  if (chainId === 31337) {
    return deployment31337 as ChainDeployment;
  }
  return null;
}

/** @deprecated use getDeployment */
export async function loadDeployment(
  chainId: number,
): Promise<ChainDeployment | null> {
  return getDeployment(chainId);
}
