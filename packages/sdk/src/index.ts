/**
 * @aml-hook/sdk — shared ABIs, types, and deployment addresses for the frontend.
 *
 * Addresses in deployments/31337.json are REAL contracts from DeployAmlStack on Anvil
 * (refresh with `npm run deploy:local`). PoolManager in that JSON may still be MockPoolManager.
 */

export { complianceOracleAbi } from "./abis/complianceOracle.js";
export { amlHookAbi } from "./abis/amlHook.js";
export {
  getDeployment,
  loadDeployment,
  type ChainDeployment,
} from "./deployments.js";
export type { Address, HookDecision, WalletRisk } from "./types.js";

export const CONTRACTS = [
  "SanctionRegistry",
  "ComplianceOracle",
  "RiskPolicy",
  "AmlHook",
] as const;

export type ContractName = (typeof CONTRACTS)[number];

export const SDK_VERSION = "0.1.0";

/** Anvil account #0 — default DeployAmlStack keeper. */
export const ANVIL_KEEPER_PRIVATE_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
