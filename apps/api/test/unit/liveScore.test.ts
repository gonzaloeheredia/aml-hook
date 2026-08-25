import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { scoreResultFromAgentDraft } from "../../src/oracle/liveScore.js";
import { demoWallet } from "../fixtures.js";

describe("unit: live score parse", () => {
  it("clamps score and maps hook bands from the agent number", () => {
    const wallet = demoWallet("B", { hopDistance: 1, originId: "A" });
    const result = scoreResultFromAgentDraft(
      {
        finalScore: 65,
        recommendedFeeBps: 800,
        triggeringFacts: [
          {
            type: "HIGH_RISK_COUNTERPARTY",
            dimension: "NW",
            confidence: "HIGH",
            baseWeight: 65,
            justification: "1-hop from A",
            regulatoryBasis: "FATF Rec. 10",
          },
        ],
      },
      wallet,
      "transfer",
      ["fact-scoring"],
      "FULL",
    );
    assert.equal(result.finalScore, 65);
    assert.equal(result.hookOutput, "FEE_OVERRIDE");
    assert.equal(result.recommendedFeeBps, 800);
    assert.equal(result.walletId, "B");
    assert.equal(result.triggeringFacts[0]?.type, "HIGH_RISK_COUNTERPARTY");
  });

  it("forces REVERT fee to 0 and clamps 0–100", () => {
    const wallet = demoWallet("A", { exploitConfirmed: true, hopDistance: 0 });
    const result = scoreResultFromAgentDraft(
      { finalScore: 140, recommendedFeeBps: 800 },
      wallet,
      "transfer",
      ["fact-scoring"],
      "FULL",
    );
    assert.equal(result.finalScore, 100);
    assert.equal(result.hookOutput, "REVERT");
    assert.equal(result.recommendedFeeBps, 0);
  });

  it("rejects a reply without finalScore", () => {
    const wallet = demoWallet("C");
    assert.throws(() =>
      scoreResultFromAgentDraft({}, wallet, "afterSwap", ["fact-scoring"], "FULL"),
    );
  });
});
