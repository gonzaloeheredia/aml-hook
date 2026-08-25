/**
 * Periodic oracle keeper: recompute scores from the live record and stamp
 * ComplianceOracle.updatedAt so Floor B does not fire on a stable wallet.
 *
 * Tick does not call Claude. It stamps the last agent score so Floor B stays quiet.
 */

import { isKeeperPending, listWallets } from "../store.js";
import { reevaluateWallet } from "./agent.js";

const DEFAULT_TICK_MS = 180_000;

/**
 * Heartbeat interval. 0 disables (tests, KEEPER_TICK=0, or invalid env).
 */
export function keeperTickMs(): number {
  if (process.env.npm_lifecycle_event === "test") return 0;
  if (process.env.KEEPER_TICK === "0") return 0;
  const raw = process.env.KEEPER_TICK_MS;
  const n = raw == null || raw.trim() === "" ? DEFAULT_TICK_MS : Number(raw);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return n;
}

/**
 * Recomputes and publishes A–D (skips E and deferred Wallet D).
 */
export async function runKeeperTick(): Promise<void> {
  for (const w of listWallets()) {
    if (w.neverScored) continue;
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
