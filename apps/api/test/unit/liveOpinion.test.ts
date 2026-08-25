import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { extractJsonObject, isLiveCoaEnabled } from "../../src/oracle/liveOpinion.js";

describe("unit: live opinion", () => {
  it("extractJsonObject reads a fenced object", () => {
    const raw = "Here:\n```json\n{\"objectAndScope\":\"who\",\"legalBasis\":\"FATF\"}\n```\n";
    const parsed = extractJsonObject(raw);
    assert.equal(parsed.objectAndScope, "who");
    assert.equal(parsed.legalBasis, "FATF");
  });

  it("extractJsonObject reads a bare object", () => {
    const parsed = extractJsonObject('prefix {"recommendations":"monitor"} suffix');
    assert.equal(parsed.recommendations, "monitor");
  });

  it("isLiveCoaEnabled honors COA_LIVE=0", () => {
    const prev = process.env.COA_LIVE;
    process.env.COA_LIVE = "0";
    assert.equal(isLiveCoaEnabled(), false);
    if (prev === undefined) delete process.env.COA_LIVE;
    else process.env.COA_LIVE = prev;
  });
});
