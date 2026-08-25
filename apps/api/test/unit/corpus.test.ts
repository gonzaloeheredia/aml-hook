import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import {
  getActiveVersionAt,
  searchRegulations,
  validateCorpus,
  type CorpusDocument,
} from "../../src/oracle/corpus.js";

function sha256(content: string | Buffer): string {
  return createHash("sha256").update(content).digest("hex");
}

function writeTree(): { corpusRoot: string; old: CorpusDocument; current: CorpusDocument } {
  const repo = mkdtempSync(join(tmpdir(), "aml-corpus-"));
  const corpusRoot = join(repo, "corpus");
  mkdirSync(join(corpusRoot, "fatf"), { recursive: true });

  const oldPdf = Buffer.from("pdf-feb-2025");
  const oldTxt =
    "FATF high-risk jurisdictions call for action. Virtual assets remain in scope.";
  const newPdf = Buffer.from("pdf-jun-2025");
  const newTxt =
    "Updated FATF high-risk jurisdictions. Risk-based approach for VASP due diligence.";

  writeFileSync(join(corpusRoot, "fatf", "2025-02-21_high-risk-jurisdictions.pdf"), oldPdf);
  writeFileSync(join(corpusRoot, "fatf", "2025-02-21_high-risk-jurisdictions.txt"), oldTxt);
  writeFileSync(join(corpusRoot, "fatf", "2025-06-13_high-risk-jurisdictions.pdf"), newPdf);
  writeFileSync(join(corpusRoot, "fatf", "2025-06-13_high-risk-jurisdictions.txt"), newTxt);

  const old: CorpusDocument = {
    id: "fatf-2025-02-21-high-risk-jurisdictions",
    framework: "FATF",
    series: "high-risk-jurisdictions",
    title: "High-Risk Jurisdictions February 2025",
    sourceUrl: null,
    publicationDate: "2025-02-21",
    retrievedAt: "2025-02-22T00:00:00Z",
    pdfPath: "corpus/fatf/2025-02-21_high-risk-jurisdictions.pdf",
    txtPath: "corpus/fatf/2025-02-21_high-risk-jurisdictions.txt",
    sha256: sha256(oldPdf),
    txtSha256: sha256(oldTxt),
    supersedes: null,
    supersededBy: "fatf-2025-06-13-high-risk-jurisdictions",
    status: "superseded",
  };
  const current: CorpusDocument = {
    id: "fatf-2025-06-13-high-risk-jurisdictions",
    framework: "FATF",
    series: "high-risk-jurisdictions",
    title: "High-Risk Jurisdictions June 2025",
    sourceUrl: "https://www.fatf-gafi.org/example",
    publicationDate: "2025-06-13",
    retrievedAt: "2025-06-14T00:00:00Z",
    pdfPath: "corpus/fatf/2025-06-13_high-risk-jurisdictions.pdf",
    txtPath: "corpus/fatf/2025-06-13_high-risk-jurisdictions.txt",
    sha256: sha256(newPdf),
    txtSha256: sha256(newTxt),
    supersedes: "fatf-2025-02-21-high-risk-jurisdictions",
    supersededBy: null,
    status: "active",
  };

  writeFileSync(
    join(corpusRoot, "manifest.json"),
    JSON.stringify([old, current], null, 2),
  );
  return { corpusRoot, old, current };
}

describe("unit: corpus", () => {
  it("validateCorpus accepts the repo tree when no PDFs are loaded", () => {
    const result = validateCorpus();
    assert.equal(result.ok, true, result.errors.join("; "));
    assert.equal(result.documentCount, 0);
  });

  it("getActiveVersionAt returns the in-force document for a past date", () => {
    const { corpusRoot, old, current } = writeTree();
    const docs = [old, current];
    assert.equal(
      getActiveVersionAt("FATF", "high-risk-jurisdictions", "2025-03-01", docs)?.id,
      old.id,
    );
    assert.equal(
      getActiveVersionAt("FATF", "high-risk-jurisdictions", "2025-06-13", docs)?.id,
      current.id,
    );
    assert.equal(
      getActiveVersionAt("FATF", "high-risk-jurisdictions", "2025-01-01", docs),
      null,
    );
    const ok = validateCorpus(corpusRoot);
    assert.equal(ok.ok, true, ok.errors.join("; "));
  });

  it("searchRegulations indexes only active docs unless asOf is set", () => {
    const { corpusRoot, old, current } = writeTree();
    const live = searchRegulations("high-risk jurisdictions VASP", {
      corpusRoot,
    });
    assert.equal(live.some((h) => h.id === current.id), true);
    assert.equal(live.some((h) => h.id === old.id), false);

    const historic = searchRegulations("high-risk jurisdictions", {
      corpusRoot,
      asOf: "2025-03-15",
    });
    assert.equal(historic.some((h) => h.id === old.id), true);
    assert.equal(historic.some((h) => h.id === current.id), false);
  });

  it("validateCorpus fails two active rows in the same series", () => {
    const { corpusRoot, old, current } = writeTree();
    writeFileSync(
      join(corpusRoot, "manifest.json"),
      JSON.stringify(
        [
          { ...old, status: "active", supersededBy: null },
          { ...current, supersedes: null },
        ],
        null,
        2,
      ),
    );
    const result = validateCorpus(corpusRoot);
    assert.equal(result.ok, false);
    assert.equal(
      result.errors.some((e) => e.includes("multiple active")),
      true,
      result.errors.join("; "),
    );
  });
});
