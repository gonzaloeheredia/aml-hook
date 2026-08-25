import assert from "node:assert/strict";
import { after, describe, it } from "node:test";
import { demoWallet } from "../fixtures.js";
import { factsFromOfacScreen } from "../../src/oracle/factScoring.js";
import type { OfacScreenResult } from "../../src/oracle/ofacScreen.js";
import {
  isOfacLiveEnabled,
  parseEthAddressesFromSdn,
  pickLiveSdnAddress,
  resetOfacSdnCache,
  screenOfacAddress,
  setOfacFetch,
} from "../../src/oracle/ofacSdn.js";

const TORNADO = "0x8589427373D6D84E98730D7795D8f6f8731FDA16";
const DEMO_A = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

describe("unit: ofac sdn", () => {
  after(() => {
    setOfacFetch(null);
    resetOfacSdnCache({ disk: true });
    delete process.env.OFAC_LIVE;
  });

  it("parses ETH addresses from SDN remarks", () => {
    const text = `foo,Digital Currency Address - ETH ${TORNADO},bar`;
    const addrs = parseEthAddressesFromSdn(text);
    assert.equal(addrs.length, 1);
    assert.equal(addrs[0], TORNADO.toLowerCase());
  });

  it("isOfacLiveEnabled honors OFAC_LIVE=0", () => {
    const prev = process.env.OFAC_LIVE;
    process.env.OFAC_LIVE = "0";
    assert.equal(isOfacLiveEnabled(), false);
    if (prev === undefined) delete process.env.OFAC_LIVE;
    else process.env.OFAC_LIVE = prev;
  });

  it("screens a mocked SDN dump and misses demo Wallet A", async () => {
    process.env.OFAC_LIVE = "1";
    resetOfacSdnCache();
    setOfacFetch(async () =>
      new Response(`Digital Currency Address - ETH ${TORNADO}`, {
        status: 200,
        headers: { "last-modified": "Tue, 01 Jan 2026 00:00:00 GMT" },
      }),
    );
    const hit = await screenOfacAddress(TORNADO);
    assert.equal(hit.match, true);
    assert.equal(hit.snapshot.ok, true);
    assert.ok(hit.snapshot.addressCount >= 1);
    const miss = await screenOfacAddress(DEMO_A);
    assert.equal(miss.match, false);
  });

  it("pickLiveSdnAddress prefers Garantex when present, else first sorted live address", async () => {
    process.env.OFAC_LIVE = "1";
    const other = "0x0000000000000000000000000000000000000001";
    const garantex = "0x7ff9cfad3877f21d41da833e2f775db0569ee3d9";
    resetOfacSdnCache();
    setOfacFetch(async () =>
      new Response(`Digital Currency Address - ETH ${other} ETH ${garantex}`, {
        status: 200,
      }),
    );
    const preferred = await pickLiveSdnAddress();
    assert.equal(preferred.address, garantex);
    assert.equal(preferred.preferredHit, true);
    assert.equal(preferred.fromLiveList, true);

    resetOfacSdnCache();
    setOfacFetch(async () =>
      new Response(`Digital Currency Address - ETH ${other}`, { status: 200 }),
    );
    const fallback = await pickLiveSdnAddress();
    assert.equal(fallback.address, other);
    assert.equal(fallback.preferredHit, false);
    assert.equal(fallback.fromLiveList, true);
  });

  it("factsFromOfacScreen emits OFAC_DIRECT_MATCH on a subject hit", () => {
    const wallet = demoWallet("A", { exploitConfirmed: true });
    const ofac: OfacScreenResult = {
      snapshot: {
        ok: true,
        live: true,
        source: "mock",
        fetchedAt: new Date().toISOString(),
        publishedAt: null,
        addressCount: 1,
        stale: false,
      },
      subject: {
        address: wallet.address,
        match: true,
        registry: {
          ok: true,
          skipped: false,
          listedBefore: false,
          listedAfter: true,
          txHash: "0xabc",
        },
      },
      counterparties: [],
    };
    const facts = factsFromOfacScreen(wallet, ofac);
    assert.equal(facts[0]?.type, "OFAC_DIRECT_MATCH");
    assert.equal(facts[0]?.baseWeight, 100);
  });
});
