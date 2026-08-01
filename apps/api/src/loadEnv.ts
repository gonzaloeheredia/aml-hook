/**
 * Loads apps/api/.env.local then .env into process.env (no dotenv dependency).
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Parses KEY=VALUE lines; does not override existing process.env keys.
 */
export function loadEnvFiles(cwd = process.cwd()): void {
  for (const name of [".env.local", ".env"]) {
    const path = join(cwd, name);
    if (!existsSync(path)) continue;
    const text = readFileSync(path, "utf8");
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eq = trimmed.indexOf("=");
      if (eq <= 0) continue;
      const key = trimmed.slice(0, eq).trim();
      let value = trimmed.slice(eq + 1).trim();
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }
      if (process.env[key] === undefined) {
        process.env[key] = value;
      }
    }
  }
}
