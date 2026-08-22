import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { applyHopContamination, applyPoolSwap } from "../../src/ledger.js";
import {
  applyUnscoredBands,
  decisionFromScore,
  feeBpsFromHop,
  hopScore,
  inflowDeltaBps,
  toHookOutput,
} from "../../src/scoring.js";
import { seedDemoWallets } from "../fixtures.js";

describe("integral: A–E demo policy", () => {
  it("clean swaps do not raise hops; P2P A→B→C then quotes 8% vs 3%", () => {
    let wallets = seedDemoWallets();
    const swapped = applyPoolSwap(wallets, "B", 1_000, 30, "allow");
    assert.ok(swapped);
    assert.equal(swapped.B.hopDistance, null);
    assert.equal(hopScore(swapped.B), 0);
    assert.equal(toHookOutput(decisionFromScore(0)), "ALLOW");

    wallets = applyHopContamination(swapped, "A", "B");
    assert.equal(wallets.B.hopDistance, 1);
    assert.equal(hopScore(wallets.B), 65);
    assert.equal(feeBpsFromHop(65, 1), 800);

    wallets = applyHopContamination(wallets, "A", "B");
    assert.equal(wallets.B.hopDistance, 1);

    wallets = applyHopContamination(wallets, "B", "C");
    assert.equal(wallets.C.hopDistance, 2);
    assert.equal(hopScore(wallets.C), 42);
    assert.equal(feeBpsFromHop(42, 2), 300);
    assert.equal(feeBpsFromHop(hopScore(wallets.B), wallets.B.hopDistance), 800);
  });

  it("Wallet D: already-held funds stay ALLOW; large clean inflow is a magnitude share", () => {
    const wallets = seedDemoWallets();
    assert.equal(wallets.D.hopDistance, null);
    assert.equal(hopScore(wallets.D), 0);
    assert.equal(decisionFromScore(0), "allow");

    const afterInflowUsd = wallets.D.usdc + 10_000;
    assert.ok(inflowDeltaBps(afterInflowUsd, wallets.D.usdc) > 5_000);
    assert.equal(applyHopContamination(wallets, "C", "D").D.hopDistance, null);
  });

  it("Wallet E: dust 3%, mid 8%, $25k REVERT — hop contamination does not apply", () => {
    const wallets = applyHopContamination(seedDemoWallets(), "A", "E");
    assert.equal(wallets.E.neverScored, true);
    assert.equal(applyUnscoredBands(999).feeBps, 300);
    assert.equal(applyUnscoredBands(1_000).feeBps, 800);
    assert.equal(toHookOutput(applyUnscoredBands(25_000).decision), "REVERT");
  });
});
