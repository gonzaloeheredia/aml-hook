/**
 * SanctionRegistry reads for oracle scoring.
 * Fail-open to "not listed" when Anvil is down — Layer 1 on the hook still fail-closes.
 */

import type { Address } from "viem";
import { publicClient } from "./clients.js";
import { getChainConfig } from "./config.js";
import { registryAbi } from "./abi.js";

const ZERO = "0x0000000000000000000000000000000000000000";

/**
 * True when SanctionRegistry lists `address`. False if the stack is unavailable.
 */
export async function isSanctionedAddress(address: string): Promise<boolean> {
  try {
    const cfg = getChainConfig();
    if (!cfg.sanctionRegistry || cfg.sanctionRegistry === ZERO) return false;
    return Boolean(
      await publicClient().readContract({
        address: cfg.sanctionRegistry,
        abi: registryAbi,
        functionName: "isSanctioned",
        args: [address as Address],
      }),
    );
  } catch {
    return false;
  }
}

/**
 * Pool / token contracts the wallet may have touched in this demo.
 */
export function demoContractAddresses(): string[] {
  try {
    const cfg = getChainConfig();
    return [cfg.hook, cfg.feeToken].filter(
      (a) => a && a !== ZERO,
    ) as string[];
  } catch {
    return [];
  }
}
