import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { resolveEventSource, selectEventTrail } from "../../src/eventsQuery.js";
import type { HookEvent } from "../../src/types.js";

function ev(
  id: string,
  walletId: HookEvent["walletId"],
  source: HookEvent["source"],
): HookEvent {
  return {
    id,
    walletId,
    address: "0xabc",
    score: 0,
    decision: "ALLOW",
    feeBps: 30,
    amountUsd: source === "demo" ? 100 : 0,
    hopDistance: null,
    origin: "n/a",
    at: `2026-01-01T00:00:0${id === "d1" ? "1" : "2"}Z`,
    kind: "SwapObserved",
    source,
  };
}

describe("eventsQuery", () => {
  it("defaults A–D to demo and E to chain", () => {
    assert.equal(resolveEventSource("B", ""), "demo");
    assert.equal(resolveEventSource("E", ""), "chain");
    assert.equal(resolveEventSource("", ""), "all");
    assert.equal(resolveEventSource("E", "demo"), "demo");
  });

  it("keeps A–D on the API trail and E on chain logs", () => {
    const demo = [ev("d1", "B", "demo"), ev("d2", "E", "demo")];
    const chain = [ev("c1", "E", "chain"), ev("c2", "B", "chain")];

    const b = selectEventTrail(demo, chain, "B", "demo");
    assert.deepEqual(
      b.map((e) => e.id),
      ["d1"],
    );

    const e = selectEventTrail(demo, chain, "E", "chain");
    assert.deepEqual(
      e.map((row) => row.id),
      ["c1"],
    );
  });
});
