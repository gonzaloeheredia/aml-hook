/**
 * Reads SwapObserved logs from AmlHook so Event can show afterSwap on Sepolia
 * (live Uniswap fill or observeSwap), not only the in-memory demo trail.
 */

import { parseAbiItem, zeroAddress, type Address, type Log } from "viem";
import { idFromAddress } from "./accounts.js";
import { publicClient } from "./clients.js";
import { getChainConfig } from "./config.js";
import { mergeEventTrails } from "../eventsQuery.js";
import type { HookEvent, HookOutput } from "../types.js";

export { mergeEventTrails };

const SWAP_OBSERVED = parseAbiItem(
  "event SwapObserved(address indexed wallet, uint8 score, uint8 decision, uint24 feeBps, uint8 hopDistance, address origin)",
);

const DECISIONS: HookOutput[] = ["ALLOW", "FEE_OVERRIDE", "REVERT"];
const CHUNK = 10_000n;
const DEFAULT_LOOKBACK = 100_000n;

type SwapObservedLog = Log<bigint, number, false, typeof SWAP_OBSERVED>;

let cached: HookEvent[] = [];
let cachedToBlock = 0n;

function decisionFromOrdinal(n: number): HookOutput {
  return DECISIONS[n] ?? "ALLOW";
}

function originLabel(origin: Address): string {
  if (origin.toLowerCase() === zeroAddress) return "n/a";
  return origin;
}

/**
 * Maps a decoded SwapObserved log plus its block time into the API event shape.
 * Unknown subjects (a new EOA on the pool) are Wallet E in the use case.
 */
function eventFromLog(log: SwapObservedLog, at: string): HookEvent | null {
  const wallet = log.args.wallet;
  if (!wallet || !log.transactionHash) return null;
  const decision = decisionFromOrdinal(Number(log.args.decision ?? 0));
  return {
    id: log.logIndex == null ? log.transactionHash : `${log.transactionHash}-${log.logIndex}`,
    walletId: idFromAddress(wallet) ?? "E",
    address: wallet,
    score: Number(log.args.score ?? 0),
    decision,
    feeBps: Number(log.args.feeBps ?? 0),
    amountUsd: 0,
    hopDistance: log.args.hopDistance == null ? null : Number(log.args.hopDistance),
    origin: originLabel((log.args.origin ?? zeroAddress) as Address),
    at,
    kind: "SwapObserved",
    txHash: log.transactionHash,
    blockNumber: log.blockNumber == null ? undefined : Number(log.blockNumber),
    source: "chain",
  };
}

async function logsInRange(
  hook: Address,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<SwapObservedLog[]> {
  const client = publicClient();
  const out: SwapObservedLog[] = [];
  let start = fromBlock;
  while (start <= toBlock) {
    const end = start + CHUNK - 1n > toBlock ? toBlock : start + CHUNK - 1n;
    const chunk = await client.getLogs({
      address: hook,
      event: SWAP_OBSERVED,
      fromBlock: start,
      toBlock: end,
    });
    out.push(...chunk);
    start = end + 1n;
  }
  return out;
}

async function timestampsFor(logs: SwapObservedLog[]): Promise<Map<string, string>> {
  const client = publicClient();
  const blocks = [...new Set(logs.map((l) => l.blockNumber).filter((b): b is bigint => b != null))];
  const map = new Map<string, string>();
  await Promise.all(
    blocks.map(async (n) => {
      const block = await client.getBlock({ blockNumber: n });
      map.set(n.toString(), new Date(Number(block.timestamp) * 1000).toISOString());
    }),
  );
  return map;
}

function firstBlock(latest: bigint): bigint {
  const env = Number(process.env.SWAP_LOGS_FROM_BLOCK);
  if (Number.isFinite(env) && env > 0) return BigInt(Math.floor(env));
  return latest > DEFAULT_LOOKBACK ? latest - DEFAULT_LOOKBACK : 0n;
}

/**
 * Incremental SwapObserved index from the configured hook.
 * Fail-open callers should catch; this function throws on RPC errors.
 */
export async function listOnChainSwapObserved(): Promise<HookEvent[]> {
  const cfg = getChainConfig();
  const client = publicClient();
  const latest = await client.getBlockNumber();
  const from = cachedToBlock > 0n ? cachedToBlock + 1n : firstBlock(latest);
  if (from > latest) return cached;

  const logs = await logsInRange(cfg.hook, from, latest);
  const times = await timestampsFor(logs);
  const next: HookEvent[] = [];
  for (const log of logs) {
    const at =
      log.blockNumber != null
        ? (times.get(log.blockNumber.toString()) ?? new Date().toISOString())
        : new Date().toISOString();
    const ev = eventFromLog(log, at);
    if (ev) next.push(ev);
  }

  const byId = new Map(cached.map((e) => [e.id, e]));
  for (const e of next) byId.set(e.id, e);
  cached = [...byId.values()].sort((a, b) => a.at.localeCompare(b.at));
  cachedToBlock = latest;
  return cached;
}

