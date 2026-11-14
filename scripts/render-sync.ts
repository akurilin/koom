#!/usr/bin/env tsx
/*
 * scripts/render-sync.ts
 *
 * Report whether the koom-web service's environment variables on
 * Render match the local sources of truth. Read-only: it never changes
 * anything on Render. Fix drift in the Render dashboard (koom-web →
 * Environment), then rerun.
 *
 * Usage:
 *
 *   npm run render:sync
 *
 * Reads RENDER_API_KEY and RENDER_SERVICE_ID from web/.env.prod.local
 * and the desired values from web/.env.local. Exits 0 when every
 * expected variable is in sync, 1 otherwise. The doctor runs the same
 * comparison as a single aggregate check.
 */

import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { computeEnvDiff, type VarSyncResult } from "./lib/render";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);
const ENV_LOCAL_PATH = join(REPO_ROOT, "web", ".env.local");
const ENV_PROD_PATH = join(REPO_ROOT, "web", ".env.prod.local");

// Same minimal parser as scripts/doctor.ts, kept inline so neither
// script depends on the other.
function parseEnvFile(content: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}

async function loadEnv(path: string): Promise<Record<string, string>> {
  if (!existsSync(path)) return {};
  return parseEnvFile(await readFile(path, "utf-8"));
}

const DISPLAY: Record<
  VarSyncResult["status"],
  { icon: string; label: string }
> = {
  "in-sync": { icon: "✓", label: "in sync" },
  drift: { icon: "✗", label: "drift" },
  "missing-on-render": { icon: "+", label: "missing" },
  unresolvable: { icon: "—", label: "unresolvable" },
};

async function main(): Promise<void> {
  const localEnv = await loadEnv(ENV_LOCAL_PATH);
  const prodEnv = await loadEnv(ENV_PROD_PATH);

  if (!prodEnv.RENDER_API_KEY || !prodEnv.RENDER_SERVICE_ID) {
    console.error(
      "RENDER_API_KEY and RENDER_SERVICE_ID must be set in web/.env.prod.local. See web/.env.prod.example.",
    );
    process.exit(2);
  }

  const diff = await computeEnvDiff({
    apiKey: prodEnv.RENDER_API_KEY,
    serviceId: prodEnv.RENDER_SERVICE_ID,
    localEnv,
  });

  const keyWidth = Math.max(...diff.results.map((r) => r.key.length));
  console.log(`Render env vars for service ${prodEnv.RENDER_SERVICE_ID}:`);
  for (const r of diff.results) {
    const { icon, label } = DISPLAY[r.status];
    console.log(
      `  ${icon} ${label.padEnd(12)}  ${r.key.padEnd(keyWidth)}  ${r.humanSource}`,
    );
    if (r.notes) console.log(`      ${r.notes}`);
  }
  if (diff.unknownKeys.length > 0) {
    console.log(
      `\nIgnored (set on Render, not managed by koom): ${diff.unknownKeys.join(", ")}`,
    );
  }

  const problems = diff.results.filter((r) => r.status !== "in-sync");
  if (problems.length > 0) {
    console.log(
      `\n${problems.length} variable(s) need attention. Update them in the Render dashboard → koom-web → Environment, then rerun.`,
    );
    process.exit(1);
  }
  console.log("\nAll expected variables are in sync.");
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
