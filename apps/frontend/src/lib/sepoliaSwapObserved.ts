/**
 * Reads AmlHook SwapObserved (afterSwap) on Ethereum Sepolia for Wallet E.
 * Event does not depend on Railway indexing — logs come from the fill receipt
 * or a direct publicnode getLogs.
 */

import {
  formatUnits,
  parseAbiItem,
  parseEventLogs,
  type Address,
  type Hex,
  type Log,
  type TransactionReceipt,
} from "viem";
import type { HookChainEvent } from "@/lib/hookEvents";
import { SEPOLIA_HOOK, SEPOLIA_MOCK_USDC, USDC_DECIMALS } from "@/lib/sepoliaPool";
import { sepoliaSimClient } from "@/lib/sepoliaWallet";

const SWAP_OBSERVED = parseAbiItem(
  "event SwapObserved(address indexed wallet, uint8 score, uint8 decision, uint24 feeBps, uint8 hopDistance, address origin)",
);

const ERC20_TRANSFER = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 value)",
);

const DECISIONS = ["ALLOW", "FEE_OVERRIDE", "REVERT"] as const;
const CHUNK = 10_000n;
const DEFAULT_LOOKBACK = 50_000n;

export type SwapObservedDecoded = {
  wallet: Address;
  score: number;
  decision: (typeof DECISIONS)[number];
  feeBps: number;
  hopDistance: number;
  origin: Address;
  txHash: Hex;
  blockNumber: number;
  logIndex: number;
  timestamp: string;
  amountUsd: number;
};

function decisionFromOrdinal(n: number): (typeof DECISIONS)[number] {
  return DECISIONS[n] ?? "ALLOW";
}

function originLabel(origin: Address): string {
  if (origin === "0x0000000000000000000000000000000000000000") return "n/a";
  return origin;
}

/**
 * MockUSDC leaving `wallet` in the same tx — the exact-in notional when known.
 */
export function usdcSpentInReceipt(
  logs: Log[],
  wallet: Address,
): number {
  const transfers = parseEventLogs({
    abi: [ERC20_TRANSFER],
    logs: logs.filter(
      (l) => l.address.toLowerCase() === SEPOLIA_MOCK_USDC.toLowerCase(),
    ),
    strict: false,
  });
  let total = 0n;
  const from = wallet.toLowerCase();
  for (const log of transfers) {
    if (log.args.from?.toLowerCase() === from) {
      total += log.args.value ?? 0n;
    }
  }
  if (total === 0n) return 0;
  return Number(formatUnits(total, USDC_DECIMALS));
}

function decodeSwapObservedLogs(
  logs: Log[],
  txHash: Hex,
  blockNumber: number,
  timestamp: string,
  amountByWallet: Map<string, number>,
): SwapObservedDecoded[] {
  const observed = parseEventLogs({
    abi: [SWAP_OBSERVED],
    logs: logs.filter(
      (l) => l.address.toLowerCase() === SEPOLIA_HOOK.toLowerCase(),
    ),
    strict: false,
  });
  const out: SwapObservedDecoded[] = [];
  for (const log of observed) {
    const wallet = log.args.wallet;
    const hash = (log.transactionHash ?? txHash) as Hex;
    if (!wallet || !hash) continue;
    out.push({
      wallet,
      score: Number(log.args.score ?? 0),
      decision: decisionFromOrdinal(Number(log.args.decision ?? 0)),
      feeBps: Number(log.args.feeBps ?? 0),
      hopDistance: Number(log.args.hopDistance ?? 0),
      origin: (log.args.origin ??
        "0x0000000000000000000000000000000000000000") as Address,
      txHash: hash,
      blockNumber:
        log.blockNumber != null ? Number(log.blockNumber) : blockNumber,
      logIndex: log.logIndex ?? 0,
      timestamp,
      amountUsd: amountByWallet.get(wallet.toLowerCase()) ?? 0,
    });
  }
  return out;
}

export function swapObservedFromReceipt(
  receipt: Pick<TransactionReceipt, "logs" | "transactionHash" | "blockNumber">,
  fallbackAmountUsd = 0,
): SwapObservedDecoded[] {
  const hash = receipt.transactionHash;
  const blockNumber = Number(receipt.blockNumber);
  const decoded = decodeSwapObservedLogs(
    receipt.logs,
    hash,
    blockNumber,
    new Date().toISOString(),
    new Map(),
  );
  return decoded.map((row) => {
    const spent = usdcSpentInReceipt(receipt.logs, row.wallet);
    return {
      ...row,
      amountUsd: spent > 0 ? spent : fallbackAmountUsd,
    };
  });
}

export function hookEventFromSepolia(row: SwapObservedDecoded): HookChainEvent {
  const blocked = row.decision === "REVERT";
  return {
    id: `${row.txHash}-${row.logIndex}`,
    hookPhase: blocked ? "beforeSwap" : "afterSwap",
    eventName: blocked ? "WalletBlocked" : "SwapObserved",
    walletId: "E",
    address: row.wallet,
    score: row.score,
    decision: row.decision,
    fee: blocked ? "n/a" : `${(row.feeBps / 100).toFixed(2)}%`,
    feeBps: blocked ? 0 : row.feeBps,
    amountUsd: row.amountUsd,
    hopDistance: row.hopDistance,
    origin: originLabel(row.origin),
    timestamp: row.timestamp,
    txHash: row.txHash,
    blockNumber: row.blockNumber,
    source: "chain",
  };
}

export async function swapObservedFromTx(
  hash: Hex,
  fallbackAmountUsd = 0,
): Promise<SwapObservedDecoded[]> {
  const client = sepoliaSimClient();
  const receipt = await client.getTransactionReceipt({ hash });
  const rows = swapObservedFromReceipt(receipt, fallbackAmountUsd);
  if (receipt.blockNumber == null) return rows;
  const block = await client.getBlock({ blockNumber: receipt.blockNumber });
  const at = new Date(Number(block.timestamp) * 1000).toISOString();
  return rows.map((row) => ({ ...row, timestamp: at }));
}

/**
 * Indexed SwapObserved for one EOA. Used when Event opens without a just-mined receipt.
 */
export async function listSepoliaSwapObserved(
  wallet: Address,
): Promise<SwapObservedDecoded[]> {
  const client = sepoliaSimClient();
  const latest = await client.getBlockNumber();
  const from = latest > DEFAULT_LOOKBACK ? latest - DEFAULT_LOOKBACK : 0n;
  const logs: Log[] = [];
  let start = from;
  while (start <= latest) {
    const end = start + CHUNK - 1n > latest ? latest : start + CHUNK - 1n;
    const chunk = await client.getLogs({
      address: SEPOLIA_HOOK,
      event: SWAP_OBSERVED,
      args: { wallet },
      fromBlock: start,
      toBlock: end,
    });
    logs.push(...chunk);
    start = end + 1n;
  }
  const byBlock = new Map<string, string>();
  const blocks = [
    ...new Set(
      logs
        .map((l) => l.blockNumber)
        .filter((n): n is bigint => n != null),
    ),
  ];
  await Promise.all(
    blocks.map(async (n) => {
      const block = await client.getBlock({ blockNumber: n });
      byBlock.set(n.toString(), new Date(Number(block.timestamp) * 1000).toISOString());
    }),
  );
  return decodeSwapObservedLogs(
    logs,
    (logs[0]?.transactionHash ?? "0x") as Hex,
    0,
    new Date().toISOString(),
    new Map(),
  ).map((row) => ({
    ...row,
    timestamp: byBlock.get(String(row.blockNumber)) ?? row.timestamp,
  }));
}
