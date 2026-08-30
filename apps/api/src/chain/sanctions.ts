/**
 * SanctionRegistry reads/writes for the COA.
 * Fail-open to "not listed" when Anvil is down. Layer 1 on the hook still fail-closes.
 * Writes use `_REGISTRY_KEEPER` (Anvil #0 locally; REGISTRY_KEEPER_PRIVATE_KEY on Sepolia).
 */

import type { Address, Hex } from "viem";
import { publicClient, registryWallet } from "./clients.js";
import { getChainConfig } from "./config.js";
import { registryAbi } from "./abi.js";

const ZERO = "0x0000000000000000000000000000000000000000";

export type SanctionWriteResult = {
  ok: boolean;
  skipped: boolean;
  listedBefore: boolean;
  listedAfter: boolean;
  txHash?: Hex;
  error?: string;
};

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
 * Immediate `setSanctioned` when the mapping does not already match `sanctioned`.
 * OFAC SDN is a public list. Commit-reveal applies to unpublished designations. This sync writes immediately.
 */
export async function writeSanction(
  address: string,
  sanctioned: boolean,
): Promise<SanctionWriteResult> {
  const listedBefore = await isSanctionedAddress(address);
  if (listedBefore === sanctioned) {
    return {
      ok: true,
      skipped: true,
      listedBefore,
      listedAfter: listedBefore,
    };
  }
  try {
    const cfg = getChainConfig();
    if (!cfg.sanctionRegistry || cfg.sanctionRegistry === ZERO) {
      return {
        ok: false,
        skipped: false,
        listedBefore,
        listedAfter: listedBefore,
        error: "SanctionRegistry missing",
      };
    }
    const { account, client } = registryWallet();
    const hash = await client.writeContract({
      address: cfg.sanctionRegistry,
      abi: registryAbi,
      functionName: "setSanctioned",
      args: [address as Address, sanctioned],
      account,
      chain: client.chain,
    });
    await publicClient().waitForTransactionReceipt({ hash });
    return {
      ok: true,
      skipped: false,
      listedBefore,
      listedAfter: sanctioned,
      txHash: hash,
    };
  } catch (err) {
    return {
      ok: false,
      skipped: false,
      listedBefore,
      listedAfter: listedBefore,
      error: err instanceof Error ? err.message : String(err),
    };
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
