import type { Address } from "./types.js";
import deployment31337 from "../deployments/31337.json" with { type: "json" };

/**
 * Anvil / local deployment addresses from `script/Deploy.sol`.
 * Refresh with `npm run deploy:local` (writes AccessManager + role holders).
 */
export type ChainDeployment = {
  chainId: number;
  deployer: Address;
  SanctionRegistry: Address;
  ComplianceOracle: Address;
  RiskPolicy: Address;
  AmlHook: Address;
  /** Shared OpenZeppelin AccessManager (AccessManaged targets) */
  AccessManager?: Address;
  admin?: Address;
  registryKeeper?: Address;
  /** Key granted `_ORACLE_KEEPER` — must match apps/api KEEPER_PRIVATE_KEY for RPC publish */
  oracleKeeper?: Address;
  hookGovernor?: Address;
  attestor?: Address;
  FeeEscrow?: Address;
  /** Authority ledger: LP principal (immediate) and recovered illicit risk fees. */
  ComplianceTreasury?: Address;
  /** Clean / early / default FeeEscrow destination (never the reserve). */
  lpCompensationFund?: Address;
  /** Confirmed-illicit recover destination. Local deploy wires ComplianceTreasury. */
  complianceReserve?: Address;
  feeToken?: Address;
  /** Mintable demo ETH (MockWETH). Priced by ethUsdFeed. */
  wethToken?: Address;
  usdFeed?: Address;
  ethUsdFeed?: Address;
  poolManager?: Address;
  /** Canonical trusted router (Universal Router on live chains, MockTrustedRouter on Anvil) */
  trustedRouter?: Address;
  /**
   * @deprecated Pre-AccessManager Deploy JSON used a single `keeper` field.
   * Prefer `oracleKeeper`.
   */
  keeper?: Address;
};

/** Address that should hold `_ORACLE_KEEPER` for `updateScore`. */
export function getOracleKeeperAddress(d: ChainDeployment): Address {
  return (d.oracleKeeper ?? d.keeper ?? d.deployer) as Address;
}

/**
 * Returns checked-in deployment addresses for a chain.
 * Refresh via `node scripts/deploy-local.mjs` (writes 31337.json).
 * Sepolia is not bundled — see `contracts/deployments/11155111.json` / docs/Sepolia.md.
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
