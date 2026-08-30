import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { consultSkill, listSkillNames } from "../../src/oracle/skills.js";

describe("unit: COA skills", () => {
  it("lists uhi10-use-case among kebab-case skills", () => {
    const names = listSkillNames();
    assert.ok(names.includes("uhi10-use-case"));
    assert.ok(names.includes("uhi10-sepolia"));
    assert.ok(names.includes("fact-scoring"));
  });

  it("consultSkill returns the A–E validation skill", () => {
    const hit = consultSkill("uhi10-use-case");
    assert.ok(!("error" in hit));
    if ("error" in hit) return;
    assert.equal(hit.name, "uhi10-use-case");
    assert.match(hit.text, /100 × 0\.65/);
    assert.match(hit.text, /neverScored/);
    assert.match(hit.text, /EXPLOIT_PROTOCOL_FUNDS/);
    assert.match(hit.text, /Wallet F/);
    assert.match(hit.text, /SanctionHit/);
    assert.match(hit.text, /uhi10-sepolia/);
  });

  it("consultSkill returns the Sepolia live-pool skill", () => {
    const hit = consultSkill("uhi10-sepolia");
    assert.ok(!("error" in hit));
    if ("error" in hit) return;
    assert.equal(hit.name, "uhi10-sepolia");
    assert.match(hit.text, /11155111/);
    assert.match(hit.text, /Wallet E/);
    assert.match(hit.text, /PoolModifyLiquidityTest/);
  });

  it("consultSkill rejects path traversal", () => {
    const miss = consultSkill("../prompts/system");
    assert.ok("error" in miss);
    const empty = consultSkill("");
    assert.ok("error" in empty);
  });
});
