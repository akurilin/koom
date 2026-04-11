#!/usr/bin/env tsx
/*
 * scripts/vercel-sync.ts
 *
 * Read-only (for now) comparison of the koom production Vercel
 * environment variables against the local sources of truth. Run this
 * any time you want to see whether your Vercel deployment is still
 * configured with the values koom expects.
 *
 *   npm run vercel:sync             dry-run report (default, current behavior)
 *   npm run vercel:sync -- --write  not yet implemented — errors out
 *
 * The actual comparison lives in `scripts/lib/vercel-sync.ts` and is
 * also reused by `scripts/doctor.ts` to surface drift as a readiness
 * warning. This file is the thin CLI wrapper that reads env files,
 * calls the lib, and formats the results.
 */

import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { computeSyncDiff, type VarSyncResult } from "./lib/vercel-sync";

// ────────────────────────────────────────────────────────────────────
// Paths
// ────────────────────────────────────────────────────────────────────

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);
const ENV_LOCAL_PATH = join(REPO_ROOT, "web", ".env.local");
const ENV_PROD_PATH = join(REPO_ROOT, "web", ".env.prod.local");
const POOLER_URL_PATH = join(REPO_ROOT, "supabase", ".temp", "pooler-url");

// ────────────────────────────────────────────────────────────────────
// Minimal env file parser (same logic as scripts/doctor.ts — kept
// inline because pulling it into a shared module would force the
// doctor to take a dependency on this module too)
// ────────────────────────────────────────────────────────────────────

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

// ────────────────────────────────────────────────────────────────────
// Output formatting
// ────────────────────────────────────────────────────────────────────

interface StatusDisplay {
  icon: string;
  label: string;
}

function displayForStatus(status: VarSyncResult["status"]): StatusDisplay {
  switch (status) {
    case "in-sync":
      return { icon: "✓", label: "in sync" };
    case "drift":
      return { icon: "✗", label: "drift" };
    case "missing-on-vercel":
      return { icon: "+", label: "missing" };
    case "opaque":
      return { icon: "⚠", label: "opaque" };
    case "unknown":
      return { icon: "?", label: "unknown" };
    case "unresolvable":
      return { icon: "—", label: "unresolvable" };
  }
}

function pad(s: string, width: number): string {
  if (s.length >= width) return s;
  return s + " ".repeat(width - s.length);
}

function printReport(results: VarSyncResult[]): void {
  if (results.length === 0) {
    console.log("No variables to report.");
    return;
  }

  const keyWidth = Math.max(3, ...results.map((r) => r.key.length));
  const labelWidth = Math.max(
    6,
    ...results.map((r) => displayForStatus(r.status).label.length),
  );
  const sourceWidth = Math.max(6, ...results.map((r) => r.humanSource.length));

  console.log(
    `  ${pad("STATUS", labelWidth + 2)}  ${pad("KEY", keyWidth)}  ${pad("SOURCE", sourceWidth)}`,
  );
  console.log(
    `  ${pad("------", labelWidth + 2)}  ${pad("---", keyWidth)}  ${pad("------", sourceWidth)}`,
  );

  for (const r of results) {
    const disp = displayForStatus(r.status);
    const line = `  ${disp.icon} ${pad(disp.label, labelWidth)}  ${pad(r.key, keyWidth)}  ${pad(r.humanSource, sourceWidth)}`;
    console.log(line);
    if (r.notes) {
      console.log(`      ${r.notes}`);
    }
  }
}

// ────────────────────────────────────────────────────────────────────
// Main
// ────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  if (args.includes("--write")) {
    console.error(
      "--write mode is not yet implemented. vercel-sync currently runs in dry-run mode only.",
    );
    console.error(
      "When --write lands, it will upsert every drifted/missing variable against the Vercel project and normalize credential-shaped values to the 'sensitive' type.",
    );
    process.exit(2);
  }

  if (args.some((a) => a === "--help" || a === "-h")) {
    console.log(
      "Usage: npm run vercel:sync [-- --write]\n\n" +
        "Compare the koom production Vercel project's environment variables\n" +
        "against the local sources of truth (web/.env.local + Supabase CLI\n" +
        "link state + Vercel primary domain).\n\n" +
        "Options:\n" +
        "  --write   Apply any detected changes. NOT YET IMPLEMENTED.\n" +
        "  -h, --help   Show this help.\n\n" +
        "Exit codes:\n" +
        "  0   No detectable drift (all in-sync or opaque)\n" +
        "  1   Detectable drift, missing variables, or unresolvable sources\n" +
        "  2   Usage error or --write requested\n",
    );
    return;
  }

  console.log("koom Vercel sync (dry run)");
  console.log("──────────────────────────");

  const localEnv = await loadEnv(ENV_LOCAL_PATH);
  const prodEnv = await loadEnv(ENV_PROD_PATH);

  if (!prodEnv.VERCEL_TOKEN || !prodEnv.VERCEL_PROJECT_ID) {
    console.error(
      "\nVERCEL_TOKEN and VERCEL_PROJECT_ID must be set in web/.env.prod.local.",
    );
    console.error(
      "Run `npm run doctor` once to bootstrap the file from its template, then fill in both values.",
    );
    process.exit(1);
  }

  console.log(
    `\nReading current Vercel env vars for project ${prodEnv.VERCEL_PROJECT_ID}...`,
  );
  console.log("Computing desired values from local sources...\n");

  const diff = await computeSyncDiff({
    vercelToken: prodEnv.VERCEL_TOKEN,
    vercelProjectId: prodEnv.VERCEL_PROJECT_ID,
    localEnv,
    poolerUrlPath: POOLER_URL_PATH,
  });

  if (diff.error) {
    console.error(`\nVercel sync failed: ${diff.error}`);
    process.exit(1);
  }

  printReport(diff.results);

  const { summary } = diff;
  console.log("");
  console.log("Summary:");
  console.log(`  ${summary.inSync} in sync`);
  if (summary.opaque > 0) {
    console.log(
      `  ${summary.opaque} opaque (sensitive type — cannot verify; --write would overwrite)`,
    );
  }
  if (summary.drift > 0) console.log(`  ${summary.drift} drift`);
  if (summary.missing > 0)
    console.log(`  ${summary.missing} missing on Vercel`);
  if (summary.unresolvable > 0)
    console.log(
      `  ${summary.unresolvable} unresolvable (local source missing)`,
    );
  if (summary.unknown > 0)
    console.log(
      `  ${summary.unknown} unknown extra var on Vercel (not managed by koom)`,
    );

  console.log("");
  if (
    summary.drift === 0 &&
    summary.missing === 0 &&
    summary.unresolvable === 0
  ) {
    console.log("No detectable drift. --write would not change anything.");
    if (summary.opaque > 0) {
      console.log(
        `(${summary.opaque} sensitive variable${summary.opaque === 1 ? "" : "s"} could not be verified, but --write would overwrite them if run.)`,
      );
    }
  } else {
    const writeHint =
      summary.writesNeeded > 0
        ? `--write would upsert ${summary.writesNeeded} variable${summary.writesNeeded === 1 ? "" : "s"} (not yet implemented).`
        : "No writes would be made even with --write.";
    console.log(
      `Detectable drift / missing / unresolvable found. ${writeHint}`,
    );
  }

  console.log("");
  console.log("This was a DRY RUN. No changes were made to Vercel.");

  // Exit code: 0 if everything is in-sync or opaque, 1 if there is
  // detectable drift that a human needs to do something about.
  process.exit(summary.allInSyncOrOpaque ? 0 : 1);
}

main().catch((err) => {
  console.error(
    `\nUnexpected error: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}`,
  );
  process.exit(1);
});
