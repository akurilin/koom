#!/usr/bin/env tsx
/*
 * scripts/vercel-sync.ts
 *
 * Compare (and optionally apply) the koom production Vercel
 * environment variables against the local sources of truth. The
 * comparison logic lives in `scripts/lib/vercel-sync.ts` and is
 * shared with `scripts/doctor.ts`, which runs the same comparison as
 * an aggregate readiness check.
 *
 * Usage:
 *
 *   npm run vercel:sync
 *     Dry run only. Reports per-variable drift, prints a plan, and
 *     exits 0 if there is no detectable drift, 1 otherwise. Safe to
 *     run any time.
 *
 *   npm run vercel:sync -- --write
 *     Prints the dry-run report plus the write plan, then REFUSES to
 *     apply anything because --yes was not passed. Treats this as a
 *     safety gate against accidental writes.
 *
 *   npm run vercel:sync -- --write --yes
 *     Prints the dry-run report AND applies the writes against the
 *     Vercel project. Every write is logged as it happens. Exits 0
 *     only if every attempted write succeeded.
 */

import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  applySyncDiff,
  computeSyncDiff,
  type SyncDiff,
  type VarSyncResult,
  type WriteEvent,
  type WriteReport,
} from "./lib/vercel-sync";

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
// Output formatting for the dry-run report
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

function printDryRunSummary(diff: SyncDiff): void {
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
}

// ────────────────────────────────────────────────────────────────────
// Output formatting for the write path
// ────────────────────────────────────────────────────────────────────

function displayForAction(action: WriteEvent["action"]): StatusDisplay {
  switch (action) {
    case "create":
      return { icon: "+", label: "create" };
    case "update":
      return { icon: "~", label: "update" };
    case "replace":
      return { icon: "↻", label: "replace" };
    case "skip":
      return { icon: "·", label: "skip" };
  }
}

function printWritePlan(diff: SyncDiff): void {
  // Only list variables that would actually produce a write. Opaque
  // variables are listed separately because they're unconditional
  // overwrites — the user should understand that's what's about to
  // happen to their sensitive values.
  const writable = diff.results.filter((r) => r.wouldWrite);
  if (writable.length === 0) {
    console.log("No writes would be performed.");
    return;
  }

  console.log("Planned writes:");
  for (const r of writable) {
    let action: string;
    switch (r.status) {
      case "missing-on-vercel":
        action = "CREATE (sensitive)";
        break;
      case "drift":
        action =
          r.currentType === "sensitive"
            ? "UPDATE (value only)"
            : `REPLACE (normalize type from '${r.currentType}' to 'sensitive')`;
        break;
      case "opaque":
        action = "OVERWRITE (sensitive — current value cannot be verified)";
        break;
      default:
        action = "(unexpected)";
    }
    console.log(`  • ${r.key} — ${action}`);
  }
}

function printWriteEvent(event: WriteEvent): void {
  const disp = displayForAction(event.action);
  const head = `  ${disp.icon} ${pad(disp.label, 8)} ${event.key}`;
  if (event.error) {
    console.log(`${head}   ✗ FAILED`);
    console.log(`      reason: ${event.reason}`);
    console.log(`      error:  ${event.error}`);
  } else if (event.action === "skip") {
    console.log(`${head}   ${event.reason}`);
  } else {
    console.log(`${head}   ✓`);
    console.log(`      ${event.reason}`);
  }
}

function printWriteSummary(report: WriteReport): void {
  console.log("");
  console.log("Write summary:");
  console.log(`  ${report.successes} succeeded`);
  if (report.failures > 0) console.log(`  ${report.failures} failed`);
  if (report.skipped > 0) console.log(`  ${report.skipped} skipped`);
}

// ────────────────────────────────────────────────────────────────────
// Main
// ────────────────────────────────────────────────────────────────────

interface Args {
  write: boolean;
  yes: boolean;
  help: boolean;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { write: false, yes: false, help: false };
  for (const a of argv) {
    if (a === "--write") args.write = true;
    else if (a === "--yes" || a === "-y") args.yes = true;
    else if (a === "--help" || a === "-h") args.help = true;
  }
  return args;
}

function printHelp(): void {
  console.log(
    "Usage: npm run vercel:sync [-- --write [--yes]]\n\n" +
      "Compare the koom production Vercel project's environment variables\n" +
      "against the local sources of truth (web/.env.local + Supabase CLI\n" +
      "link state + Vercel primary domain), and optionally apply any\n" +
      "detected drift.\n\n" +
      "Options:\n" +
      "  --write      Apply detected drift to the Vercel project. Requires\n" +
      "               --yes to actually execute; passing --write alone\n" +
      "               prints the plan and refuses to write as a safety gate.\n" +
      "  --yes, -y    Confirm that you really want to write to Vercel.\n" +
      "               Ignored unless --write is also passed.\n" +
      "  -h, --help   Show this help.\n\n" +
      "Exit codes:\n" +
      "  0   No detectable drift (dry run) or all writes succeeded (--write)\n" +
      "  1   Detectable drift, unresolvable sources, or any write failed\n" +
      "  2   Usage error (e.g. --write without --yes)\n",
  );
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) {
    printHelp();
    return;
  }

  const mode = args.write ? (args.yes ? "apply" : "write-refused") : "dry-run";

  console.log(
    mode === "apply"
      ? "koom Vercel sync (APPLY — writing to Vercel)"
      : "koom Vercel sync (dry run)",
  );
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

  const ctx = {
    vercelToken: prodEnv.VERCEL_TOKEN,
    vercelProjectId: prodEnv.VERCEL_PROJECT_ID,
    localEnv,
    poolerUrlPath: POOLER_URL_PATH,
  };

  console.log(
    `\nReading current Vercel env vars for project ${prodEnv.VERCEL_PROJECT_ID}...`,
  );
  console.log("Computing desired values from local sources...\n");

  const diff = await computeSyncDiff(ctx);

  if (diff.error) {
    console.error(`\nVercel sync failed: ${diff.error}`);
    process.exit(1);
  }

  printReport(diff.results);
  printDryRunSummary(diff);

  console.log("");

  const noDetectableDrift =
    diff.summary.drift === 0 &&
    diff.summary.missing === 0 &&
    diff.summary.unresolvable === 0;

  // ── Dry-run mode ─────────────────────────────────────────────────
  if (mode === "dry-run") {
    if (noDetectableDrift) {
      console.log("No detectable drift. --write would not change anything.");
      if (diff.summary.opaque > 0) {
        console.log(
          `(${diff.summary.opaque} sensitive variable${diff.summary.opaque === 1 ? "" : "s"} could not be verified, but --write would overwrite them if run.)`,
        );
      }
    } else {
      const writeHint =
        diff.summary.writesNeeded > 0
          ? `Rerun with --write --yes to apply ${diff.summary.writesNeeded} change${diff.summary.writesNeeded === 1 ? "" : "s"}.`
          : "No writes would be made even with --write.";
      console.log(`Detectable drift found. ${writeHint}`);
    }
    console.log("");
    console.log("This was a DRY RUN. No changes were made to Vercel.");
    process.exit(diff.summary.allInSyncOrOpaque ? 0 : 1);
  }

  // ── Safety gate: --write without --yes ───────────────────────────
  if (mode === "write-refused") {
    console.log("");
    printWritePlan(diff);
    console.log("");
    console.error(
      "Refusing to apply: --write requires --yes to confirm you actually want to push changes to Vercel.",
    );
    console.error(
      "Rerun with `npm run vercel:sync -- --write --yes` once you have reviewed the plan above.",
    );
    console.error("No changes were made to Vercel.");
    process.exit(2);
  }

  // ── Apply mode ───────────────────────────────────────────────────
  // Only reached when mode === "apply" (--write --yes).
  console.log("");
  printWritePlan(diff);
  console.log("");

  if (diff.summary.writesNeeded === 0 && diff.summary.opaque === 0) {
    console.log("Nothing to write. Exiting without touching Vercel.");
    process.exit(0);
  }

  console.log("Applying writes to Vercel...");
  console.log("");

  const report = await applySyncDiff(ctx, diff, {
    onEvent: (event) => printWriteEvent(event),
  });

  printWriteSummary(report);

  console.log("");
  if (report.allSucceeded) {
    console.log(
      "All writes succeeded. Rerun `npm run vercel:sync` (without --write) to verify.",
    );
    process.exit(0);
  } else {
    console.error(
      `${report.failures} write${report.failures === 1 ? "" : "s"} failed. Review the errors above and rerun with --write --yes after fixing them.`,
    );
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(
    `\nUnexpected error: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}`,
  );
  process.exit(1);
});
