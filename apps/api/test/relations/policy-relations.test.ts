import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { tokenAmountToUsd } from "../../src/chain/evaluate.js";
import { displayDeltaBps } from "../../src/compliance.js";
import { applyHopContamination } from "../../src/ledger.js";
import { capPublishedFeeBps } from "../../src/oracle/onchainPublisher.js";
import {
  applyUnscoredBands,
  decisionFromScore,
  feeBpsFromHop,
  hopScore,
  inflowDeltaBps,
  toHookOutput,
} from "../../src/scoring.js";
import { seedDemoWallets } from "../fixtures.js";

describe("relations: scoring × ledger × units × publisher", () => {
  it("A→B hop, score, fee, and hook output stay aligned", () => {
    const after = applyHopContamination(seedDemoWallets(), "A", "B");
    const score = hopScore(after.B);
    const fee = feeBpsFromHop(score, after.B.hopDistance);
    assert.equal(score, 65);
    assert.equal(fee, 800);
    assert.equal(decisionFromScore(score), "fee_override");
    assert.equal(toHookOutput(decisionFromScore(score)), "FEE_OVERRIDE");
    assert.equal(capPublishedFeeBps(fee), 800);
  });

  it("A→B→C hop-2 stays on the 3% band", () => {
    const afterBC = applyHopContamination(
      applyHopContamination(seedDemoWallets(), "A", "B"),
      "B",
      "C",
    );
    const score = hopScore(afterBC.C);
    assert.equal(score, 42);
    assert.equal(feeBpsFromHop(score, afterBC.C.hopDistance), 300);
    assert.equal(decisionFromScore(score), "fee_override");
  });

  it("6-dec and 18-dec token amounts produce the same inflow bps", () => {
    const inflow6 = tokenAmountToUsd(5_000n * 10n ** 6n, 6);
    const current6 = tokenAmountToUsd(10_000n * 10n ** 6n, 6);
    const inflow18 = tokenAmountToUsd(5_000n * 10n ** 18n, 18);
    const current18 = tokenAmountToUsd(10_000n * 10n ** 18n, 18);
    assert.equal(inflowDeltaBps(current6, current6 - inflow6), 5_000);
    assert.equal(
      inflowDeltaBps(current6, current6 - inflow6),
      inflowDeltaBps(current18, current18 - inflow18),
    );
    assert.equal(displayDeltaBps(inflow6, current6), 5_000);
  });

  it("Wallet E bands stay complementary to hop scoring (E never hops)", () => {
    const after = applyHopContamination(seedDemoWallets(), "A", "E");
    assert.equal(after.E.neverScored, true);
    assert.equal(hopScore(after.E), 0);
    assert.equal(applyUnscoredBands(500).feeBps, 300);
    assert.equal(applyUnscoredBands(1_000).feeBps, 800);
    assert.equal(applyUnscoredBands(25_000).decision, "block");
  });

  it("publisher cap cannot publish a fee the hook would reject", () => {
    const uncapped = feeBpsFromHop(65, 1) * 20;
    assert.ok(uncapped > 1_000);
    assert.equal(capPublishedFeeBps(uncapped), 1_000);
  });
});
