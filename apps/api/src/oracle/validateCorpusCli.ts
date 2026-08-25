/**
 * CLI: npm run validate:corpus
 * Exits 1 when corpus/manifest.json and files on disk disagree.
 */

import { validateCorpus } from "./corpus.js";

const result = validateCorpus();
if (!result.ok) {
  console.error(`corpus validation failed (${result.errors.length} error(s), ${result.documentCount} document(s)):`);
  for (const err of result.errors) {
    console.error(`  - ${err}`);
  }
  process.exit(1);
}

console.log(`corpus ok: ${result.documentCount} document(s)`);
