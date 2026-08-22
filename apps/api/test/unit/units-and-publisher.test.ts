import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { tokenAmountToUsd } from "../../src/chain/evaluate.js";
import { usdcToWei, weiToUsdc } from "../../src/chain/units.js";
import { displayDeltaBps } from "../../src/compliance.js";
import { capPublishedFeeBps } from "../../src/oracle/onchainPublisher.js";

describe("unit: units + publisher cap + display delta", () => {
  it("usdcToWei / weiToUsdc assume MockFeeToken 18 decimals", () => {
    assert.equal(usdcToWei(1_000), 1000n * 10n ** 18n);
    assert.equal(weiToUsdc(1000n * 10n ** 18n), 1_000);
  });

  it("tokenAmountToUsd uses the token decimal count", () => {
    assert.equal(tokenAmountToUsd(1_000n * 10n ** 18n, 18), 1_000);
    assert.equal(tokenAmountToUsd(1_000n * 10n ** 6n, 6), 1_000);
    assert.equal(tokenAmountToUsd(999n * 10n ** 6n, 6), 999);
    assert.equal(
      tokenAmountToUsd(1_000n * 10n ** 6n, 6),
      tokenAmountToUsd(1_000n * 10n ** 18n, 18),
    );
  });

  it("capPublishedFeeBps matches FeeBps.MAX_OVERRIDE = 1000", () => {
    assert.equal(capPublishedFeeBps(800), 800);
    assert.equal(capPublishedFeeBps(1_000), 1_000);
    assert.equal(capPublishedFeeBps(10_000), 1_000);
    assert.equal(capPublishedFeeBps(-12), 0);
    assert.equal(capPublishedFeeBps(300.4), 300);
  });

  it("displayDeltaBps is display-only and zero-safe", () => {
    assert.equal(displayDeltaBps(5_000, 10_000), 5_000);
    assert.equal(displayDeltaBps(5_000, 0), 0);
  });
});
