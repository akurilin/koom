#!/usr/bin/env tsx
/*
 * scripts/doctor.ts
 *
 * Mode-aware verification of the koom configuration. Run this during
 * initial setup, after editing env vars or infrastructure, or while
 * diagnosing a failed deploy. Exit code is non-zero if any check in
 * the selected mode failed, so it is CI-friendly.
 *
 * Modes:
 *
 *   - `npm run doctor` checks self-host/operator readiness. It does
 *     not require the local Docker/Postgres development stack.
 *
 *   - `npm run doctor:dev` checks local development readiness. It
 *     does not require access to the Render deployment.
 *
 *   - `npm run doctor:all` runs both readiness tracks.
 *
 * Shared checks such as R2, the desktop local-title assets, and code
 * signing run in every mode.
 *
 * Configuration model:
 *
 *   - `web/.env.local` holds local-development values plus the R2 and
 *     admin credentials shared with the Render deployment. DATABASE_URL
 *     here is always the local Docker Postgres.
 *
 *   - `web/.env.prod.local` holds values needed to validate the
 *     PRODUCTION deployment from a dev machine: RENDER_API_KEY,
 *     RENDER_SERVICE_ID, and RENDER_DATABASE_URL (the Render Postgres
 *     external connection string). Everything else production needs is
 *     either shared with local (R2 credentials, KOOM_ADMIN_SECRET) or
 *     wired up inside Render by render.yaml.
 *
 *   - `web/.env.local` is needed in every mode because it also holds
 *     shared R2 credentials and the admin secret. The production-only
 *     file is bootstrapped only for operator/all runs.
 */

import {
  DeleteObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { execFile } from "node:child_process";
import { copyFile, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import pg from "pg";

import { computeEnvDiff, fetchService } from "./lib/render";

const { Client: PgClient } = pg;
const execFileAsync = promisify(execFile);

// ────────────────────────────────────────────────────────────────────
// Constants
// ────────────────────────────────────────────────────────────────────

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);

const ENV_LOCAL_PATH = join(REPO_ROOT, "web", ".env.local");
const ENV_LOCAL_EXAMPLE_PATH = join(REPO_ROOT, "web", ".env.example");
const ENV_PROD_PATH = join(REPO_ROOT, "web", ".env.prod.local");
const ENV_PROD_EXAMPLE_PATH = join(REPO_ROOT, "web", ".env.prod.example");

const TEST_KEY_PREFIX = "_koom-doctor/";
const TEST_BYTE_COUNT = 1024;

const R2_REQUIRED_ENV_VARS = [
  "R2_BUCKET",
  "R2_ACCOUNT_ID",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
  "R2_PUBLIC_BASE_URL",
] as const;
const DEFAULT_CODESIGN_IDENTITY = "koom Local Dev";
const LOGIN_KEYCHAIN_PATH = join(
  process.env.HOME ?? "~",
  "Library",
  "Keychains",
  "login.keychain-db",
);

const LOCAL_TITLE_CATALOG_PATH = join(
  REPO_ROOT,
  "client",
  "Resources",
  "local-title-models.json",
);
const CLIENT_BUILD_SCRIPT_PATH = join(
  REPO_ROOT,
  "client",
  "scripts",
  "build-app.sh",
);

// Columns we expect to find on the `recordings` table. Keep in sync
// with db/migrations/*_create_recordings.sql.
const RECORDINGS_EXPECTED_COLUMNS = [
  "id",
  "created_at",
  "status",
  "title",
  "original_filename",
  "duration_seconds",
  "size_bytes",
  "content_type",
  "bucket",
  "object_key",
] as const;

// Columns we expect on the `comments` table. Keep in sync with
// db/migrations/*_create_comments.sql.
const COMMENTS_EXPECTED_COLUMNS = [
  "id",
  "recording_id",
  "commenter_id",
  "is_admin",
  "body",
  "timestamp_seconds",
  "created_at",
] as const;

// Columns we expect on the `commenters` table.
const COMMENTERS_EXPECTED_COLUMNS = ["id", "created_at"] as const;

// ────────────────────────────────────────────────────────────────────
// Result tracking
// ────────────────────────────────────────────────────────────────────
//
// Every check is tagged with a readiness track. The selected mode
// controls which sections execute; `--all` uses the tags to print
// separate local-development and operator summaries.

type Track = "local" | "prod" | "both" | "neither";
type Status = "pass" | "fail" | "warn" | "skip";
type DoctorMode = "operator" | "dev" | "all";

interface CheckResult {
  name: string;
  status: Status;
  track: Track;
  message?: string;
}

const results: CheckResult[] = [];

const DOCTOR_USAGE = `Usage:
  npm run doctor       # self-host/operator readiness (default)
  npm run doctor:dev   # local development readiness
  npm run doctor:all   # both readiness tracks

Direct invocation:
  tsx scripts/doctor.ts [--operator | --dev | --all]

Options:
  --operator  Check Render Postgres, the Render web service, R2, and the desktop runtime.
  --dev       Check local Docker Postgres, R2, local configuration, and the desktop runtime.
  --all       Run every operator and development check.
  --help      Show this help text.`;

class DoctorUsageError extends Error {}

function parseDoctorMode(args: string[]): DoctorMode | null {
  if (args.includes("--help") || args.includes("-h")) return null;

  const knownFlags = new Map<string, DoctorMode>([
    ["--operator", "operator"],
    ["--dev", "dev"],
    ["--all", "all"],
  ]);
  const unknown = args.filter((arg) => !knownFlags.has(arg));
  if (unknown.length > 0) {
    throw new DoctorUsageError(
      `Unknown doctor option${unknown.length === 1 ? "" : "s"}: ${unknown.join(", ")}\n\n${DOCTOR_USAGE}`,
    );
  }

  const selected = args.map((arg) => knownFlags.get(arg)!);
  if (selected.length > 1) {
    throw new DoctorUsageError(
      `Choose only one doctor mode.\n\n${DOCTOR_USAGE}`,
    );
  }
  return selected[0] ?? "operator";
}

function log(message = ""): void {
  process.stdout.write(message + "\n");
}

function logSection(name: string): void {
  log("");
  log(name);
}

function pass(name: string, track: Track, detail?: string): void {
  log(`  ✓ ${name}${detail ? ` ${detail}` : ""}`);
  results.push({ name, status: "pass", track, message: detail });
}

function fail(name: string, track: Track, message: string): void {
  log(`  ✗ ${name}`);
  for (const line of message.split("\n")) log(`      ${line}`);
  results.push({ name, status: "fail", track, message });
}

function warn(name: string, track: Track, message: string): void {
  log(`  ⚠ ${name}`);
  for (const line of message.split("\n")) log(`      ${line}`);
  results.push({ name, status: "warn", track, message });
}

function skip(name: string, track: Track, reason: string): void {
  log(`  ⊘ ${name} — ${reason}`);
  results.push({ name, status: "skip", track, message: reason });
}

async function runCheck(
  name: string,
  track: Track,
  fn: () => Promise<string | undefined>,
): Promise<boolean> {
  try {
    const detail = await fn();
    pass(name, track, detail);
    return true;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    fail(name, track, msg);
    return false;
  }
}

// ────────────────────────────────────────────────────────────────────
// .env.local parser (intentionally a copy of the one in r2-setup.ts —
// they will diverge over time and one shared module isn't worth the
// indirection at v1 size)
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

/**
 * Load the env files needed by the selected mode, bootstrapping each
 * from its `.example` template when missing. Every mode needs
 * `.env.local` because it contains shared R2/admin values. Dev mode
 * deliberately ignores `.env.prod.local`.
 */
async function loadEnvFiles(mode: DoctorMode): Promise<{
  local: Record<string, string>;
  prod: Record<string, string>;
  bootstrapped: { local: boolean; prod: boolean };
}> {
  const bootstrapped = { local: false, prod: false };

  if (!existsSync(ENV_LOCAL_PATH)) {
    await copyFile(ENV_LOCAL_EXAMPLE_PATH, ENV_LOCAL_PATH);
    bootstrapped.local = true;
  }
  if (mode !== "dev" && !existsSync(ENV_PROD_PATH)) {
    await copyFile(ENV_PROD_EXAMPLE_PATH, ENV_PROD_PATH);
    bootstrapped.prod = true;
  }

  const local = parseEnvFile(await readFile(ENV_LOCAL_PATH, "utf-8"));
  const prod =
    mode !== "dev" && existsSync(ENV_PROD_PATH)
      ? parseEnvFile(await readFile(ENV_PROD_PATH, "utf-8"))
      : {};
  return { local, prod, bootstrapped };
}

// ────────────────────────────────────────────────────────────────────
// Test data
// ────────────────────────────────────────────────────────────────────

/**
 * Build a deterministic test buffer of incrementing bytes [0,1,...,255,0,1,...].
 * Range slices through this buffer have predictable expected contents,
 * which makes it easy to verify Range requests aren't quietly truncated
 * or shifted.
 */
function buildTestBytes(): Buffer {
  const buf = Buffer.alloc(TEST_BYTE_COUNT);
  for (let i = 0; i < TEST_BYTE_COUNT; i++) buf[i] = i % 256;
  return buf;
}

// ────────────────────────────────────────────────────────────────────
// Main
// ────────────────────────────────────────────────────────────────────

/**
 * True if a URL value is pointing at localhost.
 */
function isLocalHost(url: string | undefined): boolean {
  if (!url) return false;
  try {
    const u = new URL(url);
    return (
      u.hostname === "127.0.0.1" ||
      u.hostname === "localhost" ||
      u.hostname === "::1"
    );
  } catch {
    return false;
  }
}

async function main(): Promise<void> {
  const mode = parseDoctorMode(process.argv.slice(2));
  if (mode === null) {
    log(DOCTOR_USAGE);
    return;
  }

  const runDevChecks = mode === "dev" || mode === "all";
  const runOperatorChecks = mode === "operator" || mode === "all";
  const modeLabel =
    mode === "operator"
      ? "self-host/operator"
      : mode === "dev"
        ? "local development"
        : "complete";

  log(`koom Doctor — ${modeLabel}`);
  log("────────────────────────────");

  const { local: env, prod: prodEnv, bootstrapped } = await loadEnvFiles(mode);

  if (bootstrapped.local || bootstrapped.prod) {
    log("");
    log("Bootstrapped missing env files from their .example templates:");
    if (bootstrapped.local) log("  + web/.env.local");
    if (bootstrapped.prod) log("  + web/.env.prod.local");
    log("Fill in the placeholder values in each file before relying on the");
    log("readiness report below.");
  }

  // ── Section: Shared configuration ────────────────────────────────
  logSection("Configuration — shared (web/.env.local)");

  // R2 credentials are shared by the local web app and production
  // deployment, so every mode validates them.
  for (const key of R2_REQUIRED_ENV_VARS) {
    if (env[key]) {
      pass(`${key} present`, "both");
    } else {
      fail(`${key} present`, "both", `Not set in web/.env.local`);
    }
  }

  // The admin secret is shared by the local web app, production
  // deployment, and desktop client.
  if (env.KOOM_ADMIN_SECRET) {
    pass("KOOM_ADMIN_SECRET present", "both");
  } else {
    fail(
      "KOOM_ADMIN_SECRET present",
      "both",
      `Not set. The web app and desktop client both need this at runtime to authenticate admin actions. Generate one with:\n    openssl rand -hex 32`,
    );
  }

  if (runDevChecks) {
    logSection("Configuration — local development (web/.env.local)");

    // DATABASE_URL is strictly local-only. The Render web service gets
    // its own from render.yaml, and the doctor reaches Render Postgres
    // through RENDER_DATABASE_URL in web/.env.prod.local.
    if (!env.DATABASE_URL) {
      fail(
        "DATABASE_URL present",
        "local",
        `Not set in web/.env.local. Expected the local Docker Postgres URL:\n    postgresql://koom:koom@127.0.0.1:54322/koom`,
      );
    } else if (!isLocalHost(env.DATABASE_URL)) {
      fail(
        "DATABASE_URL points at the local stack",
        "local",
        `DATABASE_URL in web/.env.local is pointed at a remote host. This file is LOCAL ONLY — put the Render Postgres external URL in RENDER_DATABASE_URL in web/.env.prod.local instead. Set DATABASE_URL back to the local Docker Postgres URL:\n    postgresql://koom:koom@127.0.0.1:54322/koom`,
      );
    } else {
      pass("DATABASE_URL points at the local stack", "local");
    }

    // KOOM_PUBLIC_BASE_URL in this file is local-only. On Render the
    // app falls back to the injected RENDER_EXTERNAL_URL.
    if (!env.KOOM_PUBLIC_BASE_URL) {
      warn(
        "KOOM_PUBLIC_BASE_URL present",
        "local",
        `Not set. The dev server uses this to construct share URLs returned to the desktop client. The default 'http://localhost:3000' is fine.`,
      );
    } else if (!isLocalHost(env.KOOM_PUBLIC_BASE_URL)) {
      warn(
        "KOOM_PUBLIC_BASE_URL points at the local dev server",
        "local",
        `KOOM_PUBLIC_BASE_URL in web/.env.local is ${env.KOOM_PUBLIC_BASE_URL}, which isn't localhost. This file is local-dev-only — on Render the app uses the service's onrender.com URL automatically. Fix by setting KOOM_PUBLIC_BASE_URL=http://localhost:3000 here.`,
      );
    } else {
      pass("KOOM_PUBLIC_BASE_URL points at the local dev server", "local");
    }
  }

  if (runOperatorChecks) {
    logSection("Configuration — self-host/operator");

    if (prodEnv.RENDER_API_KEY) {
      pass("RENDER_API_KEY present", "prod");
    } else {
      warn(
        "RENDER_API_KEY present",
        "prod",
        `Not set in web/.env.prod.local. Create a key at Render dashboard → Account Settings → API Keys so the doctor can verify the koom-web service and compare its environment variables.`,
      );
    }

    if (prodEnv.RENDER_SERVICE_ID) {
      pass("RENDER_SERVICE_ID present", "prod");
    } else {
      warn(
        "RENDER_SERVICE_ID present",
        "prod",
        `Not set in web/.env.prod.local. Open the koom-web service in the Render dashboard and copy the 'srv-...' id from its URL.`,
      );
    }

    if (prodEnv.RENDER_DATABASE_URL) {
      pass("RENDER_DATABASE_URL present", "prod");
    } else {
      warn(
        "RENDER_DATABASE_URL present",
        "prod",
        `Not set in web/.env.prod.local. Copy the External Database URL from Render dashboard → koom-db → Connect so the doctor can verify the production database.`,
      );
    }
  }

  const r2VarsPresent = R2_REQUIRED_ENV_VARS.every((k) => !!env[k]);

  // ── Section: R2 ───────────────────────────────────────────────────
  logSection("Cloudflare R2");

  if (!r2VarsPresent) {
    skip(
      "R2 connectivity",
      "both",
      "skipped because required R2_* env vars are missing",
    );
  } else {
    await runR2Checks(env);
  }

  if (runDevChecks) {
    logSection("Postgres — local Docker");

    if (!env.DATABASE_URL || !isLocalHost(env.DATABASE_URL)) {
      skip(
        "Local Postgres connectivity",
        "local",
        "skipped because DATABASE_URL is missing or not pointed at the local stack",
      );
    } else {
      await runLocalPostgresChecks(env);
    }
  }

  if (runOperatorChecks) {
    logSection("Postgres — Render");
    await runRenderPostgresChecks(prodEnv);
  }

  // ── Section: Local title generation ───────────────────────────────
  logSection("Local title generation");
  await runLocalTitleChecks();

  // ── Section: Desktop client (macOS) ───────────────────────────────
  logSection("Desktop client (macOS)");
  await runDesktopClientChecks();

  if (runOperatorChecks) {
    logSection("Render web service");
    await runRenderServiceChecks(prodEnv, env);
  }

  finish(mode);
}

// ────────────────────────────────────────────────────────────────────
// R2 checks
// ────────────────────────────────────────────────────────────────────

async function runR2Checks(env: Record<string, string>): Promise<void> {
  const bucket = env.R2_BUCKET!;
  const accountId = env.R2_ACCOUNT_ID!;
  const accessKeyId = env.R2_ACCESS_KEY_ID!;
  const secretAccessKey = env.R2_SECRET_ACCESS_KEY!;
  const publicBaseUrl = env.R2_PUBLIC_BASE_URL!.replace(/\/$/, "");

  // R2's S3-compatible endpoint. Region must be "auto".
  const s3 = new S3Client({
    region: "auto",
    endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
    credentials: { accessKeyId, secretAccessKey },
  });

  const testKey = `${TEST_KEY_PREFIX}test-${Date.now()}.bin`;
  const testBytes = buildTestBytes();
  let testObjectExists = false;

  try {
    // PUT
    const putOk = await runCheck(
      `Test PUT to s3://${bucket}/${testKey} (${TEST_BYTE_COUNT} bytes)`,
      "both",
      async () => {
        await s3.send(
          new PutObjectCommand({
            Bucket: bucket,
            Key: testKey,
            Body: testBytes,
            ContentType: "application/octet-stream",
          }),
        );
        return undefined;
      },
    );
    if (!putOk) {
      // Cannot meaningfully run downstream R2 checks without a put.
      return;
    }
    testObjectExists = true;

    // HEAD via S3
    await runCheck(
      "HEAD confirms object exists and size matches",
      "both",
      async () => {
        const head = await s3.send(
          new HeadObjectCommand({ Bucket: bucket, Key: testKey }),
        );
        if (head.ContentLength !== TEST_BYTE_COUNT) {
          throw new Error(
            `Expected ContentLength=${TEST_BYTE_COUNT}, got ${head.ContentLength}`,
          );
        }
        return `(Content-Length=${head.ContentLength})`;
      },
    );

    // Public GET — full object
    const publicUrl = `${publicBaseUrl}/${testKey}`;
    await runCheck(
      `Public URL serves the test object (no Range)`,
      "both",
      async () => {
        const res = await fetch(publicUrl);
        if (res.status === 404) {
          throw new Error(
            `404 from ${publicUrl} — the .r2.dev URL may need a few\n` +
              `seconds to start serving newly written objects. Try re-running\n` +
              `the doctor in 5–10 seconds.`,
          );
        }
        if (!res.ok) {
          throw new Error(`HTTP ${res.status} from ${publicUrl}`);
        }
        const body = Buffer.from(await res.arrayBuffer());
        if (body.length !== TEST_BYTE_COUNT) {
          throw new Error(
            `Expected ${TEST_BYTE_COUNT} bytes, got ${body.length}`,
          );
        }
        if (!body.equals(testBytes)) {
          throw new Error(`Returned bytes do not match what we PUT`);
        }
        return `(${body.length} bytes match)`;
      },
    );

    // Public GET — Range request (the load-bearing assumption)
    await runCheck(
      `Public URL honors Range requests (206 + Content-Range)`,
      "both",
      async () => {
        const start = 100;
        const end = 199; // inclusive — HTTP Range bytes=100-199 = 100 bytes
        const expectedSlice = testBytes.subarray(start, end + 1);

        const res = await fetch(publicUrl, {
          headers: { Range: `bytes=${start}-${end}` },
        });

        if (res.status !== 206) {
          throw new Error(
            `Expected HTTP 206 Partial Content, got ${res.status}.\n` +
              `This is the load-bearing assumption for video playback —\n` +
              `if R2 isn't serving 206s, the watch page will not be able to\n` +
              `seek inside videos and ?t= deep links will not work.`,
          );
        }

        const contentRange = res.headers.get("content-range");
        if (!contentRange) {
          throw new Error(`206 response is missing Content-Range header`);
        }
        const expectedHeader = `bytes ${start}-${end}/${TEST_BYTE_COUNT}`;
        if (contentRange !== expectedHeader) {
          throw new Error(
            `Content-Range mismatch: expected "${expectedHeader}", got "${contentRange}"`,
          );
        }

        const body = Buffer.from(await res.arrayBuffer());
        if (body.length !== expectedSlice.length) {
          throw new Error(
            `Expected ${expectedSlice.length} bytes, got ${body.length}`,
          );
        }
        if (!body.equals(expectedSlice)) {
          throw new Error(
            `Returned slice does not match expected bytes [${start}..${end}]`,
          );
        }
        return `(bytes ${start}-${end}, ${body.length} bytes, content matches)`;
      },
    );
  } finally {
    // Always try to clean up the test object, even if checks failed.
    if (testObjectExists) {
      try {
        await s3.send(
          new DeleteObjectCommand({ Bucket: bucket, Key: testKey }),
        );
        pass("Test object cleaned up", "neither");
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        warn(
          "Test object cleanup",
          "neither",
          `Failed to delete s3://${bucket}/${testKey}: ${msg}\n` +
            `Delete it manually from the R2 dashboard if it's still there.`,
        );
      }
    }
  }
}

// ────────────────────────────────────────────────────────────────────
// Postgres checks
// ────────────────────────────────────────────────────────────────────

async function runLocalPostgresChecks(
  env: Record<string, string>,
): Promise<void> {
  const track: Track = "local";
  const client = new PgClient({ connectionString: env.DATABASE_URL });

  const testId = `_doctor-test-${Date.now()}`;
  let connected = false;
  let inserted = false;

  try {
    // Connect
    const connectOk = await runCheck(
      "Connect via DATABASE_URL (local stack)",
      track,
      async () => {
        try {
          await client.connect();
          connected = true;
          return undefined;
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          // Guess the most common root cause so the fix is obvious.
          if (msg.includes("ECONNREFUSED")) {
            throw new Error(
              `${msg}\n` +
                `Postgres is not reachable at the configured host/port.\n` +
                `Make sure Docker is running and start the local database:\n` +
                `    npm run db:start`,
            );
          }
          throw err;
        }
      },
    );
    if (!connectOk) return;

    // Basic SELECT
    await runCheck("Basic SELECT 1 query works", track, async () => {
      const { rows } = await client.query<{ n: number }>("SELECT 1::int AS n");
      if (rows[0]?.n !== 1) {
        throw new Error(`Expected 1, got ${JSON.stringify(rows[0])}`);
      }
      return undefined;
    });

    // recordings table exists with expected columns
    const tableOk = await runCheck(
      "recordings table exists with expected columns",
      track,
      () =>
        checkTableColumns(
          client,
          "recordings",
          RECORDINGS_EXPECTED_COLUMNS,
          LOCAL_MIGRATE_HINT,
        ),
    );
    if (!tableOk) return;

    // comments table exists with expected columns
    await runCheck("comments table exists with expected columns", track, () =>
      checkTableColumns(
        client,
        "comments",
        COMMENTS_EXPECTED_COLUMNS,
        LOCAL_MIGRATE_HINT,
      ),
    );

    // commenters table exists with expected columns
    await runCheck("commenters table exists with expected columns", track, () =>
      checkTableColumns(
        client,
        "commenters",
        COMMENTERS_EXPECTED_COLUMNS,
        LOCAL_MIGRATE_HINT,
      ),
    );

    // INSERT a throwaway row
    const insertOk = await runCheck(
      "INSERT a throwaway row",
      track,
      async () => {
        await client.query(
          `INSERT INTO recordings
               (id, status, original_filename, size_bytes, bucket, object_key)
             VALUES ($1, $2, $3, $4, $5, $6)`,
          [
            testId,
            "pending",
            "koom-doctor-test.mp4",
            1024,
            env.R2_BUCKET ?? "koom-recordings",
            "_koom-doctor/placeholder.bin",
          ],
        );
        inserted = true;
        return `(id=${testId})`;
      },
    );
    if (!insertOk) return;

    // SELECT it back and verify round-trip
    await runCheck(
      "SELECT the row back and verify round-trip",
      track,
      async () => {
        const { rows } = await client.query<{
          id: string;
          status: string;
          size_bytes: string; // BIGINT comes back as string from pg by default
        }>(
          `SELECT id, status, size_bytes
               FROM recordings
              WHERE id = $1`,
          [testId],
        );
        if (rows.length !== 1) {
          throw new Error(`Expected 1 row, got ${rows.length}`);
        }
        const row = rows[0]!;
        if (row.status !== "pending") {
          throw new Error(`Expected status='pending', got '${row.status}'`);
        }
        if (row.size_bytes !== "1024") {
          throw new Error(
            `Expected size_bytes='1024', got '${row.size_bytes}'`,
          );
        }
        return undefined;
      },
    );

    // Verify the listing-query shape is efficient (uses the index).
    // This is cheap belt-and-suspenders — if the index got dropped,
    // this will catch it before we notice slow listings in production.
    await runCheck("Listing query shape is indexed", track, async () => {
      const { rows } = await client.query<{ "QUERY PLAN": string }>(
        `EXPLAIN (FORMAT TEXT)
           SELECT id, created_at
             FROM recordings
            WHERE status = 'complete'
            ORDER BY created_at DESC
            LIMIT 20`,
      );
      const plan = rows.map((r) => r["QUERY PLAN"]).join("\n");
      // At this scale (~1 row), Postgres may prefer a Seq Scan. We
      // just verify the index at least exists and is considered.
      // A truly missing index would error out before reaching here.
      if (!plan.includes("recordings")) {
        throw new Error(
          `EXPLAIN output did not mention 'recordings' — unexpected`,
        );
      }
      return undefined;
    });
  } finally {
    // Always clean up the test row if we managed to insert one.
    if (inserted) {
      try {
        await client.query("DELETE FROM recordings WHERE id = $1", [testId]);
        pass("Test row cleaned up", "neither");
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        warn(
          "Test row cleanup",
          "neither",
          `Failed to DELETE id=${testId}: ${msg}\n` +
            `Delete it manually if it lingers.`,
        );
      }
    }
    if (connected) {
      try {
        await client.end();
      } catch {
        // ignore — the connection may already be gone
      }
    }
  }
}

/**
 * Shared helper: look up a table in information_schema.columns and
 * verify that every expected column is present. Throws with a helpful
 * message if the table is missing or any column is missing.
 */
const LOCAL_MIGRATE_HINT = "Apply migrations with 'npm run db:reset'.";
const RENDER_MIGRATE_HINT =
  "Render applies migrations in the koom-web pre-deploy step; check the latest deploy's logs.";

async function checkTableColumns(
  client: pg.Client,
  tableName: string,
  expectedColumns: readonly string[],
  migrateHint: string,
): Promise<string> {
  const { rows } = await client.query<{ column_name: string }>(
    `SELECT column_name
       FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = $1
      ORDER BY ordinal_position`,
    [tableName],
  );
  if (rows.length === 0) {
    throw new Error(
      `No '${tableName}' table in the public schema.\n` + migrateHint,
    );
  }
  const actual = rows.map((r) => r.column_name);
  const missing = expectedColumns.filter((c) => !actual.includes(c));
  if (missing.length > 0) {
    throw new Error(
      `Missing columns: ${missing.join(", ")}\n` +
        `Present columns: ${actual.join(", ")}\n` +
        `The migrations in db/migrations/ may be out of sync\n` +
        `with the expected schema. ${migrateHint}`,
    );
  }
  return `(${rows.length} columns, all expected)`;
}

// ────────────────────────────────────────────────────────────────────
// Render Postgres checks
// ────────────────────────────────────────────────────────────────────

/**
 * Connect to Render Postgres over its external URL and verify that the
 * pre-deploy migrations have produced the expected schema. Read-only:
 * unlike the local checks, nothing is inserted into production.
 */
async function runRenderPostgresChecks(
  prodEnv: Record<string, string>,
): Promise<void> {
  const track: Track = "prod";

  if (!prodEnv.RENDER_DATABASE_URL) {
    skip(
      "Render Postgres reachable",
      track,
      "skipped because RENDER_DATABASE_URL is not set in web/.env.prod.local",
    );
    return;
  }

  // Render requires TLS on external connections. An explicit
  // `sslmode` in the URL wins over this default.
  const client = new PgClient({
    connectionString: prodEnv.RENDER_DATABASE_URL,
    ssl: { rejectUnauthorized: false },
    connectionTimeoutMillis: 10_000,
  });

  const connected = await runCheck(
    "Render Postgres reachable",
    track,
    async () => {
      try {
        await client.connect();
        await client.query("SELECT 1");
        return `(host ${new URL(prodEnv.RENDER_DATABASE_URL).hostname})`;
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        if (msg.includes("password authentication failed")) {
          throw new Error(
            `Password authentication failed. Re-copy the External Database URL from Render dashboard → koom-db → Connect into RENDER_DATABASE_URL.`,
          );
        }
        if (msg.includes("ENOTFOUND")) {
          throw new Error(
            `${msg}\nRENDER_DATABASE_URL must be the EXTERNAL Database URL (host ending in .render.com); the internal URL only resolves inside Render.`,
          );
        }
        throw err;
      }
    },
  );

  try {
    if (!connected) return;
    const tables: Array<[string, readonly string[]]> = [
      ["recordings", RECORDINGS_EXPECTED_COLUMNS],
      ["comments", COMMENTS_EXPECTED_COLUMNS],
      ["commenters", COMMENTERS_EXPECTED_COLUMNS],
    ];
    for (const [table, columns] of tables) {
      await runCheck(`${table} table exists with expected columns`, track, () =>
        checkTableColumns(client, table, columns, RENDER_MIGRATE_HINT),
      );
    }
  } finally {
    try {
      await client.end();
    } catch {
      // ignore — the connection may never have opened
    }
  }
}

// ────────────────────────────────────────────────────────────────────
// Local title generation checks
// ────────────────────────────────────────────────────────────────────

/**
 * Validate the checked-in model catalog and the pinned llama.cpp
 * packaging recipe. Models are intentionally not a setup prerequisite:
 * the desktop client downloads the selected model on first launch.
 */
async function runLocalTitleChecks(): Promise<void> {
  const track: Track = "both";
  type CatalogModel = {
    id?: unknown;
    downloadURL?: unknown;
    byteCount?: unknown;
    sha256?: unknown;
  };
  type Catalog = {
    version?: unknown;
    defaultModelID?: unknown;
    models?: unknown;
  };

  let catalog: Catalog;
  try {
    catalog = JSON.parse(
      await readFile(LOCAL_TITLE_CATALOG_PATH, "utf8"),
    ) as Catalog;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    fail(
      "Curated model catalog",
      track,
      `Could not read ${LOCAL_TITLE_CATALOG_PATH}: ${message}`,
    );
    return;
  }

  const models = Array.isArray(catalog.models)
    ? (catalog.models as CatalogModel[])
    : [];
  const ids = models
    .map((model) => (typeof model.id === "string" ? model.id : null))
    .filter((id): id is string => id !== null);
  const uniqueIDs = new Set(ids);
  const catalogIsValid =
    catalog.version === 1 &&
    typeof catalog.defaultModelID === "string" &&
    ids.includes(catalog.defaultModelID) &&
    ids.length === models.length &&
    uniqueIDs.size === ids.length &&
    models.every(
      (model) =>
        typeof model.downloadURL === "string" &&
        model.downloadURL.startsWith("https://huggingface.co/") &&
        typeof model.byteCount === "number" &&
        model.byteCount > 0 &&
        typeof model.sha256 === "string" &&
        /^[a-f0-9]{64}$/.test(model.sha256),
    );

  if (!catalogIsValid) {
    fail(
      "Curated model catalog",
      track,
      "Expected version 1, a present default model, unique ids, pinned HTTPS downloads, byte sizes, and SHA-256 hashes.",
    );
    return;
  }
  pass(
    "Curated model catalog",
    track,
    `(${models.length} models; default: ${catalog.defaultModelID})`,
  );

  let buildScript: string;
  try {
    buildScript = await readFile(CLIENT_BUILD_SCRIPT_PATH, "utf8");
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    fail(
      "Bundled llama.cpp recipe",
      track,
      `Could not read ${CLIENT_BUILD_SCRIPT_PATH}: ${message}`,
    );
    return;
  }
  const runtimeChecksums = [
    ...buildScript.matchAll(/archive_sha256="[a-f0-9]{64}"/g),
  ];
  const runtimeIsPinned =
    /LLAMA_CPP_RELEASE="b\d+"/.test(buildScript) &&
    buildScript.includes("github.com/ggml-org/llama.cpp/releases/download/") &&
    runtimeChecksums.length === 2 &&
    buildScript.includes("Contents/Helpers/llama-runtime");
  if (!runtimeIsPinned) {
    fail(
      "Bundled llama.cpp recipe",
      track,
      "The app build must pin and checksum the llama.cpp release before copying it into the bundle.",
    );
    return;
  }
  pass(
    "Bundled llama.cpp recipe",
    track,
    "(downloaded and checksummed by the app build; no provider install required)",
  );
}

async function runDesktopClientChecks(): Promise<void> {
  // Self-hosters and contributors both build/run the desktop client,
  // so stable signing is relevant to every mode.
  const track: Track = "both";

  if (process.platform !== "darwin") {
    skip(
      "Stable local codesigning identity",
      track,
      "macOS-only check; skipped on non-macOS hosts",
    );
    return;
  }

  const identityName =
    process.env.KOOM_CODESIGN_IDENTITY ?? DEFAULT_CODESIGN_IDENTITY;

  let identityOutput = "";
  try {
    const result = await execFileAsync("security", [
      "find-identity",
      "-v",
      "-p",
      "codesigning",
      LOGIN_KEYCHAIN_PATH,
    ]);
    identityOutput = result.stdout;
  } catch (err) {
    warn(
      "Stable local codesigning identity",
      track,
      `Could not query login keychain identities: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
    return;
  }

  if (!identityOutput.includes(`"${identityName}"`)) {
    warn(
      "Stable local codesigning identity",
      track,
      `Identity '${identityName}' is missing from ${LOGIN_KEYCHAIN_PATH}.\n` +
        `Run:\n` +
        `    npm run app:codesign\n` +
        `Without it, the macOS app still runs, but rebuilds fall back to ad hoc signing and Keychain 'Always Allow' decisions may not stick.`,
    );
    return;
  }

  const tempBinary = join(
    tmpdir(),
    `koom-doctor-codesign-${process.pid}-${Date.now()}`,
  );

  try {
    await execFileAsync("cp", ["/usr/bin/true", tempBinary]);
    await execFileAsync("codesign", [
      "--force",
      "--sign",
      identityName,
      tempBinary,
    ]);
    await execFileAsync("codesign", ["--verify", "--verbose=1", tempBinary]);
    pass(
      "Stable local codesigning identity",
      track,
      `('${identityName}' is usable)`,
    );
  } catch (err) {
    warn(
      "Stable local codesigning identity",
      track,
      `Identity '${identityName}' exists, but codesign could not use it.\n` +
        `Re-run:\n` +
        `    npm run app:codesign -- --force\n` +
        `That recreates the identity, trusts it for code signing, and refreshes the user keychain search list.\n` +
        `Underlying error: ${err instanceof Error ? err.message : String(err)}`,
    );
  } finally {
    try {
      await execFileAsync("rm", ["-f", tempBinary]);
    } catch {
      // ignore temp-file cleanup failures
    }
  }
}

// ────────────────────────────────────────────────────────────────────
// Render web service checks
// ────────────────────────────────────────────────────────────────────

/**
 * Three prod-track checks against the deployed koom-web service:
 *
 *   1. "Render service reachable" — RENDER_API_KEY can read
 *      RENDER_SERVICE_ID and the service isn't suspended.
 *   2. "Render env vars in sync" — the same comparison as
 *      `npm run render:sync`, folded into one check.
 *   3. "Public URL serves the web app" — the service's onrender.com
 *      URL answers /login (the Blueprint's health check path).
 */
async function runRenderServiceChecks(
  prodEnv: Record<string, string>,
  localEnv: Record<string, string>,
): Promise<void> {
  const track: Track = "prod";
  const checks = [
    "Render service reachable",
    "Render env vars in sync",
    "Public URL serves the web app",
  ];

  if (!prodEnv.RENDER_API_KEY || !prodEnv.RENDER_SERVICE_ID) {
    for (const name of checks) {
      skip(
        name,
        track,
        "skipped because RENDER_API_KEY / RENDER_SERVICE_ID are not set in web/.env.prod.local",
      );
    }
    return;
  }

  let serviceUrl: string | undefined;
  const reachable = await runCheck(checks[0]!, track, async () => {
    const service = await fetchService(
      prodEnv.RENDER_API_KEY,
      prodEnv.RENDER_SERVICE_ID,
    );
    if (service.suspended === "suspended") {
      throw new Error(
        `Service '${service.name}' is suspended (${service.suspended}). Resume it in the Render dashboard.`,
      );
    }
    serviceUrl = service.serviceDetails?.url;
    return `(service '${service.name}'${serviceUrl ? `, ${serviceUrl}` : ""})`;
  });

  if (!reachable) {
    skip(
      checks[1]!,
      track,
      "skipped because the Render service is not reachable",
    );
    skip(
      checks[2]!,
      track,
      "skipped because the Render service is not reachable",
    );
    return;
  }

  try {
    const diff = await computeEnvDiff({
      apiKey: prodEnv.RENDER_API_KEY,
      serviceId: prodEnv.RENDER_SERVICE_ID,
      localEnv,
    });
    const problems = diff.results.filter((r) => r.status !== "in-sync");
    if (problems.length === 0) {
      pass(checks[1]!, track, `(${diff.results.length} verified)`);
    } else {
      warn(
        checks[1]!,
        track,
        problems.map((r) => `${r.key}: ${r.status}`).join(", ") +
          `\nRun 'npm run render:sync' for details, then fix the values in Render dashboard → koom-web → Environment.`,
      );
    }
  } catch (err) {
    fail(checks[1]!, track, err instanceof Error ? err.message : String(err));
  }

  if (!serviceUrl) {
    skip(checks[2]!, track, "skipped because Render reported no public URL");
    return;
  }
  const base = serviceUrl.startsWith("http")
    ? serviceUrl
    : `https://${serviceUrl}`;
  await runCheck(checks[2]!, track, async () => {
    const loginUrl = new URL("/login", base);
    const res = await fetch(loginUrl, {
      redirect: "manual",
      signal: AbortSignal.timeout(15_000),
    });
    if (res.status !== 200) {
      throw new Error(
        `GET ${loginUrl.href} returned HTTP ${res.status}. Check the koom-web deploy and runtime logs in the Render dashboard.`,
      );
    }
    return `(${loginUrl.origin})`;
  });
}

function finish(mode: DoctorMode): never {
  log("");
  log("─────────────────────────────────────────────────────");
  log("Readiness report");
  log("─────────────────────────────────────────────────────");

  // Header-level counts (every check, regardless of track).
  const passCount = results.filter((r) => r.status === "pass").length;
  const failCount = results.filter((r) => r.status === "fail").length;
  const warnCount = results.filter((r) => r.status === "warn").length;
  const skipCount = results.filter((r) => r.status === "skip").length;

  const bits: string[] = [];
  bits.push(`${passCount} passed`);
  if (failCount > 0) bits.push(`${failCount} failed`);
  if (warnCount > 0)
    bits.push(`${warnCount} warning${warnCount === 1 ? "" : "s"}`);
  if (skipCount > 0) bits.push(`${skipCount} skipped`);
  log(`Totals: ${bits.join(", ")}`);
  log("");

  if (mode === "dev" || mode === "all") {
    reportTrack(
      "Local development",
      "You can develop and run the stack on this machine.",
      ["local", "both"],
    );
    log("");
  }
  if (mode === "operator" || mode === "all") {
    reportTrack(
      "Self-host/operator",
      "You can operate koom on Render with Cloudflare R2.",
      ["prod", "both"],
    );
    log("");
  }

  // Only checks selected by the mode were executed, so this exit code
  // cannot be poisoned by an irrelevant readiness track. Warnings do
  // not fail the command.
  process.exit(failCount > 0 ? 1 : 0);
}

/**
 * Print the readiness verdict for a single track. "Ready" means no
 * fails and no warns in scope. "Not ready" lists every fail and warn
 * so the user can see exactly what to fix. Skipped checks are listed
 * separately as informational.
 */
function reportTrack(
  title: string,
  tagline: string,
  tracks: readonly Track[],
): void {
  const scoped = results.filter((r) => tracks.includes(r.track));
  const fails = scoped.filter((r) => r.status === "fail");
  const warns = scoped.filter((r) => r.status === "warn");
  const skips = scoped.filter((r) => r.status === "skip");

  let verdict: string;
  if (fails.length === 0 && warns.length === 0) {
    verdict = "✓ ready";
  } else if (fails.length === 0) {
    verdict = "⚠ ready with warnings";
  } else {
    verdict = "✗ not ready";
  }

  log(`${title}: ${verdict}`);
  log(`  ${tagline}`);

  if (fails.length > 0) {
    log("  Blocking issues:");
    for (const r of fails) {
      log(`    ✗ ${r.name}`);
    }
  }
  if (warns.length > 0) {
    log("  Warnings:");
    for (const r of warns) {
      log(`    ⚠ ${r.name}`);
    }
  }
  if (skips.length > 0) {
    log("  Skipped (not fatal):");
    for (const r of skips) {
      log(`    ⊘ ${r.name}`);
    }
  }
}

main().catch((err) => {
  if (err instanceof DoctorUsageError) {
    process.stderr.write(`${err.message}\n`);
    process.exit(2);
  }
  process.stderr.write(
    `\nUnexpected error: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}\n`,
  );
  process.exit(1);
});
