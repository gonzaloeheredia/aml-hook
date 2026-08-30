import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { applyHopContamination, applyPoolSwap } from "../../src/ledger.js";
import { seedDemoWallets } from "../fixtures.js";

describe("unit: ledger", () => {
  it("applyHopContamination: A→B is hop 1; B stays hop 1 after another A inbound", () => {
    const afterAB = applyHopContamination(seedDemoWallets(), "A", "B");
    assert.equal(afterAB.B.hopDistance, 1);
    assert.equal(afterAB.B.originId, "A");
    const again = applyHopContamination(afterAB, "A", "B");
    assert.equal(again.B.hopDistance, 1);
  });

  it("applyHopContamination: B→C after A→B is hop 2", () => {
    const afterAB = applyHopContamination(seedDemoWallets(), "A", "B");
    const afterBC = applyHopContamination(afterAB, "B", "C");
    assert.equal(afterBC.C.hopDistance, 2);
    assert.equal(afterBC.C.originId, "A");
  });

  it("applyHopContamination: never-scored E is not contaminated", () => {
    const after = applyHopContamination(seedDemoWallets(), "A", "E");
    assert.equal(after.E.hopDistance, null);
    assert.equal(after.E.neverScored, true);
  });

  it("applyHopContamination: clean→clean does not add a hop", () => {
    const after = applyHopContamination(seedDemoWallets(), "B", "C");
    assert.equal(after.C.hopDistance, null);
  });

  it("applyPoolSwap: ALLOW settles without changing hops; REVERT is a no-op", () => {
    const wallets = seedDemoWallets();
    const settled = applyPoolSwap(wallets, "B", 1_000, 30, "allow");
    assert.ok(settled);
    assert.equal(settled.B.usdc, 24_000);
    assert.equal(settled.B.hopDistance, null);
    assert.equal(applyPoolSwap(wallets, "A", 1_000, 0, "block"), null);
  });
});
