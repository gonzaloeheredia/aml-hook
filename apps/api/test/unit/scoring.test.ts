import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  applyNeverScoredFloors,
  applyUnscoredBands,
  decisionFromScore,
  ethOutFromSwap,
  feeBand,
  feeBpsFromHop,
  hopScore,
  inflowDeltaBps,
  isWalletId,
  scoreTier,
  shouldPublishScore,
  swapUsdcAmount,
  toHookOutput,
  walletScore,
} from "../../src/scoring.js";
import { demoWallet } from "../fixtures.js";
import { dustExampleUsd, midBandExampleUsd } from "../../src/chain/policy.js";

describe("unit: scoring", () => {
  it("hopScore: exploit, clean, 1-hop, 2-hop, never-scored", () => {
    assert.equal(hopScore(demoWallet("A", { exploitConfirmed: true, hopDistance: 0 })), 100);
    assert.equal(hopScore(demoWallet("B")), 0);
    assert.equal(hopScore(demoWallet("B", { hopDistance: 1 })), 65);
    assert.equal(hopScore(demoWallet("C", { hopDistance: 2 })), 42);
    assert.equal(hopScore(demoWallet("E", { neverScored: true, hopDistance: 1 })), 0);
  });

  it("decisionFromScore: ALLOW / FEE_OVERRIDE / REVERT bands", () => {
    assert.equal(decisionFromScore(0), "allow");
    assert.equal(decisionFromScore(30), "allow");
    assert.equal(decisionFromScore(31), "fee_override");
    assert.equal(decisionFromScore(70), "fee_override");
    assert.equal(decisionFromScore(71), "block");
    assert.equal(decisionFromScore(100), "block");
  });

  it("feeBpsFromHop: clean 0.30%, 1-hop 8%, 2-hop 3%, revert 0", () => {
    assert.equal(feeBpsFromHop(0, null), 30);
    assert.equal(feeBpsFromHop(65, 1), 800);
    assert.equal(feeBpsFromHop(42, 2), 300);
    assert.equal(feeBpsFromHop(100, 0), 0);
  });

  it("demo size examples follow live fee / revert floors", () => {
    assert.equal(dustExampleUsd(1_000), 500);
    assert.equal(dustExampleUsd(400), 200);
    assert.equal(midBandExampleUsd(1_000, 15_000), 10_000);
    assert.equal(midBandExampleUsd(2_000, 8_000), 5_000);
  });

  it("applyNeverScoredFloors: bag $500 → 3%; $15k bag → 8% on a small swap; $15k this swap → block", () => {
    assert.equal(applyNeverScoredFloors(500, 500).feeBps, 300);
    assert.equal(applyNeverScoredFloors(500, 10_000).feeBps, 300);
    assert.equal(applyNeverScoredFloors(500, 15_000).feeBps, 800);
    assert.equal(applyNeverScoredFloors(500, 40_000).feeBps, 800);
    assert.equal(applyNeverScoredFloors(15_000, 15_000).decision, "block");
  });

  it("applyUnscoredBands: $1k / $15k Wallet E policy", () => {
    assert.deepEqual(applyUnscoredBands(0), {
      decision: "fee_override",
      feeBps: 300,
      latencyMitigation: "SCORE_NEVER_WRITTEN",
    });
    assert.deepEqual(applyUnscoredBands(999), {
      decision: "fee_override",
      feeBps: 300,
      latencyMitigation: "SCORE_NEVER_WRITTEN",
    });
    assert.deepEqual(applyUnscoredBands(1_000), {
      decision: "fee_override",
      feeBps: 800,
      latencyMitigation: "SCORE_NEVER_WRITTEN",
    });
    assert.deepEqual(applyUnscoredBands(14_999), {
      decision: "fee_override",
      feeBps: 800,
      latencyMitigation: "SCORE_NEVER_WRITTEN",
    });
    assert.deepEqual(applyUnscoredBands(15_000), {
      decision: "block",
      feeBps: 0,
      latencyMitigation: "SCORE_NEVER_WRITTEN",
    });
  });

  it("applyUnscoredBands / feeBpsFromHop follow live knobs", () => {
    const knobs = {
      unscoredFeeThresholdUsd: 2_000,
      unscoredRevertThresholdUsd: 50_000,
      proportionalFeeBps: 50,
      punitiveFeeBps: 1_500,
      poolImpactThresholdBps: 2_000,
    };
    assert.equal(applyUnscoredBands(1_500, knobs).feeBps, 50);
    assert.equal(applyUnscoredBands(2_000, knobs).feeBps, 1_500);
    assert.equal(applyUnscoredBands(50_000, knobs).decision, "block");
    assert.equal(feeBpsFromHop(65, 1, knobs), 1_500);
    assert.equal(feeBpsFromHop(42, 2, knobs), 50);
  });

  it("inflowDeltaBps: share of current bag", () => {
    assert.equal(inflowDeltaBps(10_000, 5_000), 5_000);
    assert.equal(inflowDeltaBps(0, 0), 0);
    assert.equal(inflowDeltaBps(5_000, 5_000), 0);
  });

  it("toHookOutput / scoreTier / feeBand / isWalletId", () => {
    assert.equal(toHookOutput("allow"), "ALLOW");
    assert.equal(toHookOutput("fee_override"), "FEE_OVERRIDE");
    assert.equal(toHookOutput("block"), "REVERT");
    assert.equal(scoreTier(30), "allow");
    assert.equal(scoreTier(31), "fee");
    assert.equal(scoreTier(71), "revert");
    assert.equal(feeBand(800), 800);
    assert.equal(feeBand(300), 300);
    assert.equal(feeBand(30), 30);
    assert.equal(feeBand(0), 0);
    assert.equal(isWalletId("A"), true);
    assert.equal(isWalletId("E"), true);
    assert.equal(isWalletId("N"), false);
    assert.equal(isWalletId("F"), false);
    assert.equal(isWalletId("Z"), false);
    assert.equal(hopScore(demoWallet("A", { exploitConfirmed: true, hopDistance: 0 })), 100);
  });

  it("shouldPublishScore: first write, band change, staleness", () => {
    assert.equal(
      shouldPublishScore({
        neverScored: true,
        priorScore: null,
        nextScore: 0,
        priorFeeBps: null,
        nextFeeBps: 300,
        lastScoreAt: null,
        now: 1_000,
        stalenessMs: 300_000,
      }),
      false,
    );
    assert.equal(
      shouldPublishScore({
        neverScored: false,
        priorScore: null,
        nextScore: 0,
        priorFeeBps: null,
        nextFeeBps: 30,
        lastScoreAt: null,
        now: 1_000,
        stalenessMs: 300_000,
      }),
      true,
    );
    assert.equal(
      shouldPublishScore({
        neverScored: false,
        priorScore: 0,
        nextScore: 65,
        priorFeeBps: 30,
        nextFeeBps: 800,
        lastScoreAt: 1,
        now: 2,
        stalenessMs: 300_000,
      }),
      true,
    );
    assert.equal(
      shouldPublishScore({
        neverScored: false,
        priorScore: 0,
        nextScore: 0,
        priorFeeBps: 30,
        nextFeeBps: 30,
        lastScoreAt: 1,
        now: 2,
        stalenessMs: 300_000,
      }),
      false,
    );
    assert.equal(
      shouldPublishScore({
        neverScored: false,
        priorScore: 0,
        nextScore: 0,
        priorFeeBps: 30,
        nextFeeBps: 30,
        lastScoreAt: 1,
        now: 2,
        stalenessMs: 300_000,
        force: true,
      }),
      true,
    );
  });

  it("swapUsdcAmount and ethOutFromSwap", () => {
    assert.equal(swapUsdcAmount(demoWallet("B", { usdc: 500 }), 1_000), 500);
    assert.equal(ethOutFromSwap(1_000, 30), 0.997);
    assert.equal(ethOutFromSwap(0, 800), 0);
  });

  it("walletScore falls back to hop when oracle memory is empty", () => {
    assert.equal(walletScore(demoWallet("B", { hopDistance: 1 })), 65);
  });
});
