/**
 * Git-versioned regulatory corpus for search_regulations.
 *
 * Answers come from corpus/ only. Model training memory is not a source.
 * Operational OFAC SDN screening is SanctionRegistry, not this tree.
 */

import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const CORPUS_FRAMEWORKS = [
  "FATF",
  "OFAC",
  "MICA",
  "TFR",
  "FINCEN",
  "TREASURY",
  "WOLFSBERG",
] as const;
export type CorpusFramework = (typeof CORPUS_FRAMEWORKS)[number];
export type CorpusStatus = "active" | "superseded";

export type CorpusDocument = {
  id: string;
  framework: CorpusFramework;
  series: string;
  title: string;
  sourceUrl: string | null;
  publicationDate: string;
  retrievedAt: string;
  pdfPath: string;
  txtPath: string;
  sha256: string;
  txtSha256: string;
  supersedes: string | null;
  supersededBy: string | null;
  status: CorpusStatus;
};

export type NormativeCitation = {
  id: string;
  title: string;
  framework: CorpusFramework;
  series: string;
  publicationDate: string;
  retrievedAt: string;
  sha256: string;
};

export type RegulationHit = NormativeCitation & {
  excerpt: string;
  txtPath: string;
  score: number;
};

export type CorpusConsult = {
  citations: NormativeCitation[];
  coverageGap: boolean;
  hits: RegulationHit[];
};

export type CorpusValidation = {
  ok: boolean;
  errors: string[];
  documentCount: number;
};

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const FRAMEWORK_SET = new Set<string>(CORPUS_FRAMEWORKS);

function isFramework(value: string): value is CorpusFramework {
  return FRAMEWORK_SET.has(value);
}

/**
 * Resolves the corpus/ directory (repo root / corpus).
 */
export function resolveCorpusRoot(explicit?: string): string {
  if (explicit) return explicit;
  if (process.env.CORPUS_ROOT) return process.env.CORPUS_ROOT;
  const here = dirname(fileURLToPath(import.meta.url));
  const fromModule = join(here, "..", "..", "..", "..", "corpus");
  if (existsSync(fromModule)) return fromModule;
  const fromCwd = join(process.cwd(), "corpus");
  if (existsSync(fromCwd)) return fromCwd;
  const fromApi = join(process.cwd(), "..", "..", "corpus");
  if (existsSync(fromApi)) return fromApi;
  return fromModule;
}

function repoRootFromCorpus(corpusRoot: string): string {
  return dirname(corpusRoot);
}

function sha256Buffer(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

function sha256File(path: string): string {
  return sha256Buffer(readFileSync(path));
}

function posixJoin(root: string, rel: string): string {
  return join(root, ...rel.split("/"));
}

/**
 * Loads and lightly type-checks manifest.json. Does not hash-verify files.
 */
export function loadManifest(corpusRoot = resolveCorpusRoot()): CorpusDocument[] {
  const path = join(corpusRoot, "manifest.json");
  if (!existsSync(path)) return [];
  const raw = JSON.parse(readFileSync(path, "utf8")) as unknown;
  if (!Array.isArray(raw)) {
    throw new Error("corpus/manifest.json must be a JSON array");
  }
  return raw.map((row, i) => parseDocument(row, i));
}

function parseDocument(row: unknown, index: number): CorpusDocument {
  if (!row || typeof row !== "object") {
    throw new Error(`manifest[${index}] is not an object`);
  }
  const r = row as Record<string, unknown>;
  const str = (key: string): string => {
    const v = r[key];
    if (typeof v !== "string" || !v) {
      throw new Error(`manifest[${index}].${key} must be a non-empty string`);
    }
    return v;
  };
  const strOrNull = (key: string): string | null => {
    const v = r[key];
    if (v === null || v === undefined) return null;
    if (typeof v !== "string") {
      throw new Error(`manifest[${index}].${key} must be a string or null`);
    }
    return v;
  };
  const framework = str("framework");
  if (!isFramework(framework)) {
    throw new Error(
      `manifest[${index}].framework must be ${CORPUS_FRAMEWORKS.join(" | ")}`,
    );
  }
  const status = str("status");
  if (status !== "active" && status !== "superseded") {
    throw new Error(`manifest[${index}].status must be active | superseded`);
  }
  return {
    id: str("id"),
    framework,
    series: str("series"),
    title: str("title"),
    sourceUrl: strOrNull("sourceUrl"),
    publicationDate: str("publicationDate"),
    retrievedAt: str("retrievedAt"),
    pdfPath: str("pdfPath"),
    txtPath: str("txtPath"),
    sha256: str("sha256"),
    txtSha256: str("txtSha256"),
    supersedes: strOrNull("supersedes"),
    supersededBy: strOrNull("supersededBy"),
    status,
  };
}

function toCitation(doc: CorpusDocument): NormativeCitation {
  return {
    id: doc.id,
    title: doc.title,
    framework: doc.framework,
    series: doc.series,
    publicationDate: doc.publicationDate,
    retrievedAt: doc.retrievedAt,
    sha256: doc.sha256,
  };
}

/**
 * Document in force for (framework, series) on `asOf` (ISO date or datetime).
 * Uses publicationDate + the supersedes chain; may return a now-superseded row.
 */
export function getActiveVersionAt(
  framework: CorpusFramework,
  series: string,
  asOf: string,
  docs: CorpusDocument[] = loadManifest(),
): CorpusDocument | null {
  const asOfDay = asOf.slice(0, 10);
  const candidates = docs
    .filter(
      (d) =>
        d.framework === framework &&
        d.series === series &&
        d.publicationDate <= asOfDay,
    )
    .sort((a, b) => {
      if (a.publicationDate === b.publicationDate) return a.id.localeCompare(b.id);
      return a.publicationDate < b.publicationDate ? -1 : 1;
    });
  return candidates.at(-1) ?? null;
}

function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length > 2);
}

function chunkText(text: string, size = 1200): string[] {
  const trimmed = text.replace(/\r\n/g, "\n").trim();
  if (!trimmed) return [];
  const paras = trimmed.split(/\n{2,}/);
  const chunks: string[] = [];
  let buf = "";
  for (const p of paras) {
    if ((buf + "\n\n" + p).length > size && buf) {
      chunks.push(buf.trim());
      buf = p;
    } else {
      buf = buf ? `${buf}\n\n${p}` : p;
    }
  }
  if (buf.trim()) chunks.push(buf.trim());
  return chunks;
}

function excerptAround(chunk: string, queryTokens: string[], max = 280): string {
  const lower = chunk.toLowerCase();
  let idx = 0;
  for (const t of queryTokens) {
    const at = lower.indexOf(t);
    if (at >= 0) {
      idx = at;
      break;
    }
  }
  const start = Math.max(0, idx - 80);
  const slice = chunk.slice(start, start + max).replace(/\s+/g, " ").trim();
  const prefix = start > 0 ? "…" : "";
  const suffix = start + max < chunk.length ? "…" : "";
  return `${prefix}${slice}${suffix}`;
}

function docsForQuery(
  docs: CorpusDocument[],
  asOf?: string,
): CorpusDocument[] {
  if (!asOf) return docs.filter((d) => d.status === "active");
  const keys = new Map<string, { framework: CorpusFramework; series: string }>();
  for (const d of docs) {
    keys.set(`${d.framework}::${d.series}`, {
      framework: d.framework,
      series: d.series,
    });
  }
  const resolved: CorpusDocument[] = [];
  for (const { framework, series } of keys.values()) {
    const hit = getActiveVersionAt(framework, series, asOf, docs);
    if (hit) resolved.push(hit);
  }
  return resolved;
}

export type SearchRegulationsOpts = {
  asOf?: string;
  corpusRoot?: string;
  limit?: number;
};

/**
 * Keyword search over extracted .txt of in-force (or as-of) documents.
 */
export function searchRegulations(
  query: string,
  opts: SearchRegulationsOpts = {},
): RegulationHit[] {
  const corpusRoot = opts.corpusRoot ?? resolveCorpusRoot();
  const repoRoot = repoRootFromCorpus(corpusRoot);
  const docs = docsForQuery(loadManifest(corpusRoot), opts.asOf);
  const queryTokens = tokenize(query);
  if (!queryTokens.length) return [];

  const hits: RegulationHit[] = [];
  for (const doc of docs) {
    const absTxt = posixJoin(repoRoot, doc.txtPath);
    if (!existsSync(absTxt)) continue;
    const text = readFileSync(absTxt, "utf8");
    let bestScore = 0;
    let bestChunk = "";
    for (const chunk of chunkText(text)) {
      const hay = chunk.toLowerCase();
      let score = 0;
      for (const t of queryTokens) {
        if (hay.includes(t)) score += 1;
      }
      if (score > bestScore) {
        bestScore = score;
        bestChunk = chunk;
      }
    }
    if (bestScore <= 0) continue;
    hits.push({
      ...toCitation(doc),
      excerpt: excerptAround(bestChunk || text.slice(0, 280), queryTokens),
      txtPath: doc.txtPath,
      score: bestScore,
    });
  }

  hits.sort((a, b) => b.score - a.score || a.id.localeCompare(b.id));
  return hits.slice(0, opts.limit ?? 8);
}

export type WalletCorpusHint = {
  exploitConfirmed: boolean;
  hopDistance: number | null;
};

function queryForWallet(wallet: WalletCorpusHint): string {
  const parts = [
    "virtual assets VASP risk-based approach due diligence recommendation",
    "convertible virtual currency money transmitter DeFi decentralised finance digital assets",
  ];
  if (wallet.exploitConfirmed) {
    parts.push("sanctions designated virtual currency stolen funds illicit");
  }
  if (wallet.hopDistance != null && wallet.hopDistance > 0) {
    parts.push("ongoing monitoring customer due diligence third party");
  }
  parts.push("travel rule crypto-asset transfer CASP kiosk");
  return parts.join(" ");
}

/**
 * Mock search_regulations call for a wallet evaluation.
 */
export function consultCorpusForWallet(
  wallet: WalletCorpusHint,
  opts: SearchRegulationsOpts = {},
): CorpusConsult {
  const hits = searchRegulations(queryForWallet(wallet), opts);
  const seen = new Set<string>();
  const citations: NormativeCitation[] = [];
  for (const hit of hits) {
    if (seen.has(hit.id)) continue;
    seen.add(hit.id);
    citations.push({
      id: hit.id,
      title: hit.title,
      framework: hit.framework,
      series: hit.series,
      publicationDate: hit.publicationDate,
      retrievedAt: hit.retrievedAt,
      sha256: hit.sha256,
    });
  }
  return {
    citations,
    coverageGap: citations.length === 0,
    hits,
  };
}

function listPdfs(corpusRoot: string): string[] {
  const pdfs: string[] = [];
  if (!existsSync(corpusRoot)) return pdfs;
  for (const framework of CORPUS_FRAMEWORKS) {
    const dir = join(corpusRoot, framework.toLowerCase());
    if (!existsSync(dir) || !statSync(dir).isDirectory()) continue;
    for (const name of readdirSync(dir)) {
      if (name.toLowerCase().endsWith(".pdf")) {
        pdfs.push(join(dir, name));
      }
    }
  }
  return pdfs;
}

function posixRel(from: string, to: string): string {
  return relative(from, to).split(sep).join("/");
}

/**
 * CI checks: disk ↔ manifest, hashes, unique active (framework, series), dates, chain.
 */
export function validateCorpus(corpusRoot = resolveCorpusRoot()): CorpusValidation {
  const errors: string[] = [];
  const repoRoot = repoRootFromCorpus(corpusRoot);

  let docs: CorpusDocument[] = [];
  try {
    docs = loadManifest(corpusRoot);
  } catch (err) {
    return {
      ok: false,
      errors: [err instanceof Error ? err.message : String(err)],
      documentCount: 0,
    };
  }

  const byId = new Map<string, CorpusDocument>();
  const activeKey = new Map<string, string[]>();

  for (const doc of docs) {
    if (byId.has(doc.id)) {
      errors.push(`duplicate id ${doc.id}`);
    }
    byId.set(doc.id, doc);

    if (!DATE_RE.test(doc.publicationDate)) {
      errors.push(`${doc.id}: publicationDate must be YYYY-MM-DD`);
    }
    if (Number.isNaN(Date.parse(doc.retrievedAt))) {
      errors.push(`${doc.id}: retrievedAt is not a valid ISO timestamp`);
    }

    const pdfAbs = posixJoin(repoRoot, doc.pdfPath);
    const txtAbs = posixJoin(repoRoot, doc.txtPath);
    if (!existsSync(pdfAbs)) {
      errors.push(`${doc.id}: missing PDF ${doc.pdfPath}`);
    } else if (sha256File(pdfAbs) !== doc.sha256) {
      errors.push(`${doc.id}: sha256 does not match ${doc.pdfPath}`);
    }
    if (!existsSync(txtAbs)) {
      errors.push(`${doc.id}: missing txt ${doc.txtPath}`);
    } else if (sha256File(txtAbs) !== doc.txtSha256) {
      errors.push(`${doc.id}: txtSha256 does not match ${doc.txtPath}`);
    }

    if (doc.supersedes && !docs.some((d) => d.id === doc.supersedes)) {
      errors.push(`${doc.id}: supersedes ${doc.supersedes} is not in the manifest`);
    }
    if (doc.supersededBy && !docs.some((d) => d.id === doc.supersededBy)) {
      errors.push(`${doc.id}: supersededBy ${doc.supersededBy} is not in the manifest`);
    }
    if (doc.supersedes) {
      const prev = docs.find((d) => d.id === doc.supersedes);
      if (prev && prev.supersededBy !== doc.id) {
        errors.push(
          `${doc.id}: supersedes ${prev.id} but that row supersededBy is ${prev.supersededBy}`,
        );
      }
    }

    if (doc.status === "active") {
      const key = `${doc.framework}::${doc.series}`;
      const ids = activeKey.get(key) ?? [];
      ids.push(doc.id);
      activeKey.set(key, ids);
    }
  }

  for (const [key, ids] of activeKey) {
    if (ids.length > 1) {
      errors.push(`multiple active documents for ${key}: ${ids.join(", ")}`);
    }
  }

  const listedPdfs = new Set(docs.map((d) => d.pdfPath.replace(/\\/g, "/")));
  for (const abs of listPdfs(corpusRoot)) {
    const rel = posixRel(repoRoot, abs);
    if (!listedPdfs.has(rel)) {
      errors.push(`PDF on disk with no manifest row: ${rel}`);
    }
  }

  return {
    ok: errors.length === 0,
    errors,
    documentCount: docs.length,
  };
}
