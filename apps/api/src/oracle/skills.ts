/**
 * Load COA markdown skills from agents/oracle-coa/skills.
 * Live Claude uses consult_skill; never serve files outside that folder.
 */

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SKILL_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

function repoRoot(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  return join(here, "..", "..", "..", "..");
}

export function skillsDir(): string {
  return join(repoRoot(), "agents", "oracle-coa", "skills");
}

/**
 * Kebab-case skill names present on disk (no .md).
 */
export function listSkillNames(): string[] {
  const dir = skillsDir();
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((n) => n.endsWith(".md"))
    .map((n) => n.slice(0, -3))
    .filter((n) => SKILL_NAME.test(n))
    .sort();
}

/**
 * Returns the skill markdown, or an error object if the name is not a skill.
 */
export function consultSkill(name: string): {
  name: string;
  path: string;
  text: string;
} | { error: string; available: string[] } {
  const trimmed = name.trim().toLowerCase().replace(/\.md$/, "");
  const available = listSkillNames();
  if (!SKILL_NAME.test(trimmed) || trimmed.includes("..") || trimmed.includes("/") || trimmed.includes("\\")) {
    return { error: `invalid skill name ${name}`, available };
  }
  const path = join(skillsDir(), `${trimmed}.md`);
  if (!existsSync(path)) {
    return { error: `unknown skill ${trimmed}`, available };
  }
  return {
    name: trimmed,
    path: `agents/oracle-coa/skills/${trimmed}.md`,
    text: readFileSync(path, "utf8"),
  };
}
