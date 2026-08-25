import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildFacts, scoreFromFacts } from "../../src/oracle/factScoring.js";
import type { FactEvent } from "../../src/oracle/types.js";
import { keeperTickMs } from "../../src/oracle/keeper.js";
import type { HookEvent, TransferRecord } from "../../src/types.js";
import { demoWallet } from "../fixtures.js";

function scoreOf(
  wallet: ReturnType<typeof demoWallet>,
  transfers: TransferRecord[] = [],
  events: HookEvent[] = [],
  extra: FactEvent[] = [],
) {
  const facts = buildFacts(wallet, transfers, events, extra);
  return scoreFromFacts(wallet, facts, "manual", null, ["fact-scoring"], "FULL");
}

function hopTransfer(from: "A" | "B", to: "B" | "C"): TransferRecord {
  return {
    id: `${from}-${to}`,
    from,
    to,
    amountUsd: 10_000,
    at: new Date().toISOString(),
    resultingScore: from === "A" ? 65 : 42,
    hopDistance: from === "A" ? 1 : 2,
  };
}

function swapEvent(
  walletId: "B" | "C" | "D",
  decision: HookEvent["decision"],
  i = 0,
): HookEvent {
  return {
    id: `swap-${walletId}-${i}`,
    walletId,
    address: `0x${walletId.padStart(40, "0")}`,
    score: 0,
    decision,
    feeBps: decision === "FEE_OVERRIDE" ? 800 : 30,
    amountUsd: 1_000,
    hopDistance: walletId === "B" ? 1 : null,
    origin: "A",
    at: new Date().toISOString(),
    kind: "SwapObserved",
  };
}

describe("unit: fact scoring record", () => {
  it("wallet A is locked at 100 for protocol exploit (not OFAC)", () => {
    const wallet = demoWallet("A", {
      exploitConfirmed: true,
      hopDistance: 0,
      originId: "A",
    });
    const result = scoreOf(wallet);
    assert.equal(result.finalScore, 100);
    assert.equal(result.hookOutput, "REVERT");
    assert.ok(
      result.triggeringFacts.some((f) => f.type === "EXPLOIT_PROTOCOL_FUNDS"),
    );
    assert.ok(
      result.triggeringFacts.every((f) => f.type !== "OFAC_DIRECT_MATCH"),
    );
  });

  it("1-hop score is 65 before afterSwap events", () => {
    const wallet = demoWallet("B", { hopDistance: 1, originId: "A" });
    const result = scoreOf(wallet, [hopTransfer("A", "B")]);
    assert.equal(result.finalScore, 65);
    assert.equal(result.hookOutput, "FEE_OVERRIDE");
    assert.equal(result.recommendedFeeBps, 800);
  });

  it("2-hop score is 42 before afterSwap events", () => {
    const wallet = demoWallet("C", { hopDistance: 2, originId: "A" });
    const result = scoreOf(wallet, [hopTransfer("B", "C")]);
    assert.equal(result.finalScore, 42);
    assert.equal(result.recommendedFeeBps, 300);
  });

  it("one FEE_OVERRIDE afterSwap on 1-hop stays in FEE_OVERRIDE (≤70)", () => {
    const wallet = demoWallet("B", { hopDistance: 1, originId: "A" });
    const result = scoreOf(wallet, [hopTransfer("A", "B")], [
      swapEvent("B", "FEE_OVERRIDE"),
    ]);
    assert.ok(result.finalScore > 65);
    assert.ok(result.finalScore <= 70);
    assert.equal(result.hookOutput, "FEE_OVERRIDE");
    assert.ok(
      result.triggeringFacts.some((f) => f.type === "SWAP_OBSERVED_TRAIL"),
    );
    assert.ok(
      result.triggeringFacts.some(
        (f) => f.type === "AFTERSWAP_FEE_OVERRIDE_SERIES",
      ),
    );
  });

  it("clean wallet score rises with SwapObserved emits", () => {
    const wallet = demoWallet("D");
    const none = scoreOf(wallet);
    const one = scoreOf(wallet, [], [swapEvent("D", "ALLOW", 0)]);
    const two = scoreOf(wallet, [], [
      swapEvent("D", "ALLOW", 0),
      swapEvent("D", "ALLOW", 1),
    ]);
    assert.equal(none.finalScore, 0);
    assert.ok(one.finalScore > none.finalScore);
    assert.ok(two.finalScore > one.finalScore);
  });

  it("listed contract interaction fail-closes at 100", () => {
    const wallet = demoWallet("B", { hopDistance: 1, originId: "A" });
    const extra: FactEvent[] = [
      {
        factId: "s1",
        type: "SANCTIONED_CONTRACT_INTERACTION",
        confidence: "HIGH",
        baseWeight: 100,
        scoreContribution: 0,
        regulatoryBasis: "OFAC",
        justification: "hook listed",
        dimension: "S",
      },
    ];
    const result = scoreOf(wallet, [hopTransfer("A", "B")], [], extra);
    assert.equal(result.finalScore, 100);
    assert.equal(result.hookOutput, "REVERT");
  });

  it("keeper tick is disabled under npm test", () => {
    assert.equal(keeperTickMs(), 0);
  });
});
