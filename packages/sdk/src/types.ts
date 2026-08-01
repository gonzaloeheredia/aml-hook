export type Address = `0x${string}`;

export type HookDecision = "ALLOW" | "FEE_OVERRIDE" | "REVERT";

export type WalletRisk = {
  score: number;
  hopDistance: number;
  origin: Address;
  updatedAt: number;
};
