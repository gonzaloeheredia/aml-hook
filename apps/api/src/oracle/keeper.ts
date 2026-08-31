/**
 * Periodic oracle keeper: recompute scores from the live record and stamp
 * ComplianceOracle.updatedAt so Floor B does not fire on a stable wallet.
 *
 * Tick is 3 minutes (`KEEPER_TICK_MS`). Floor B arms at 5 minutes
 * (`stalenessThreshold`). The tick does not call Claude. It stamps the last
 * agent score. If the agent is down, this heartbeat still keeps a published
 * row fresh. Unbound Wallet E is skipped; a bound EOA is published on the
 * first write and then stamped like A–D.
 */

import { isBoundWalletE } from "../chain/accounts.js";
import { isKeeperPending, listWallets } from "../store.js";
import { reevaluateWallet } from "./agent.js";

const DEFAULT_TICK_MS = 180_000;

function isNodeTestRun(): boolean {
  return (
    process.env.npm_lifecycle_event === "test" ||
    process.env.NODE_TEST_CONTEXT != null
  );
}

/**
 * Heartbeat interval. 0 disables (node:test / npm test, KEEPER_TICK=0, or invalid env).
 */
export function keeperTickMs(): number {
  if (isNodeTestRun()) return 0;
  if (process.env.KEEPER_TICK === "0") return 0;
  const raw = process.env.KEEPER_TICK_MS;
  const n = raw == null || raw.trim() === "" ? DEFAULT_TICK_MS : Number(raw);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return n;
}

/**
 * Recomputes and publishes A–D and bound Wallet E (skips deferred Wallet D).
 */
export async function runKeeperTick(): Promise<void> {
  for (const w of listWallets()) {
    if (w.id === "E" && !isBoundWalletE(w.address)) continue;
    if (isKeeperPending(w.id)) continue;
    await reevaluateWallet(w.id, "tick");
  }
}

let timer: ReturnType<typeof setInterval> | null = null;
let inFlight = false;

type TickLog = {
  info: (obj: unknown, msg?: string) => void;
  error: (obj: unknown, msg?: string) => void;
};

/**
 * Starts the 3-minute heartbeat after the API is listening. No-op when disabled.
 */
export function startKeeperTicker(log?: TickLog): void {
  const ms = keeperTickMs();
  if (ms <= 0) {
    log?.info("oracle keeper tick disabled");
    return;
  }
  if (timer) clearInterval(timer);
  log?.info({ keeperTickMs: ms }, "oracle keeper tick started");
  timer = setInterval(() => {
    if (inFlight) return;
    inFlight = true;
    void runKeeperTick()
      .catch((err) => {
        log?.error({ err }, "oracle keeper tick failed");
      })
      .finally(() => {
        inFlight = false;
      });
  }, ms);
}

/**
 * Stops the heartbeat (tests / shutdown).
 */
export function stopKeeperTicker(): void {
  if (timer) clearInterval(timer);
  timer = null;
  inFlight = false;
}
