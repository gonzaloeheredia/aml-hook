/**
 * @aml-hook/sdk — shared ABIs, types, and deployment addresses for the frontend.
 *
 * Addresses in deployments/31337.json are REAL contracts from Deploy on Anvil
 * (refresh with `npm run deploy:local`). Includes AccessManager + role holders when
 * written by the current script. PoolManager may still be MockPoolManager.
 */

export { complianceOracleAbi } from "./abis/complianceOracle.js";
export { amlHookAbi } from "./abis/amlHook.js";
export {
  getDeployment,
  getOracleKeeperAddress,
  loadDeployment,
  type ChainDeployment,
} from "./deployments.js";
export type { Address, HookDecision, WalletRisk } from "./types.js";

export const CONTRACTS = [
  "AccessManager",
  "SanctionRegistry",
  "ComplianceOracle",
  "RiskPolicy",
  "AmlHook",
] as const;

export type ContractName = (typeof CONTRACTS)[number];

export const SDK_VERSION = "0.1.0";

/** Anvil account #0 — default Deploy admin / registry / oracle / hook-governor roles. */
export const ANVIL_KEEPER_PRIVATE_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
