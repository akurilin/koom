#!/usr/bin/env tsx
/*
 * scripts/doctor.ts
 *
 * Read-only verification of the koom configuration. Run this any time
 * something seems off — at initial setup, after editing env vars, or
 * after a failed deploy. Exit code is non-zero if any check failed,
 * so it's CI-friendly.
 *
 * The doctor produces a readiness report that tells you separately
 * whether local development is ready and whether production
 * deployment is ready. Each check is tagged with a "track" so the
 * final report can categorize it.
 *
 * Configuration model:
 *
 *   - `web/.env.local` holds LOCAL DEVELOPMENT values only. DATABASE_URL
 *     here is always the local Supabase stack.
 *
 *   - `web/.env.prod.local` holds values needed to validate and deploy
 *     to PRODUCTION from a dev machine (currently VERCEL_TOKEN and
 *     VERCEL_PROJECT_ID). Everything else that's technically needed
 *     for production is either shared with local (R2 credentials,
 *     KOOM_ADMIN_SECRET), stored in Vercel itself, or derived live
 *     from the Supabase CLI link (production Postgres URL).
 *
 *   - Both files are auto-forked from their `.example` templates the
 *     first time the doctor runs, so the user doesn't have to copy
 *     them by hand.
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

import { computeSyncDiff } from "./lib/vercel-sync";

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

const SUPABASE_TEMP_DIR = join(REPO_ROOT, "supabase", ".temp");
const SUPABASE_LINKED_PROJECT_PATH = join(
  SUPABASE_TEMP_DIR,
  "linked-project.json",
);
const SUPABASE_POOLER_URL_PATH = join(SUPABASE_TEMP_DIR, "pooler-url");

// Pinned version must stay in sync with the one package.json uses for
// db:start / db:push / etc. so the doctor is checking the same CLI the
// rest of the repo uses.
const SUPABASE_CLI_SPEC = "supabase@2.87.2";

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

// Auto-title defaults must stay in sync with Autotitler.swift on the
// client. The doctor reads overrides from its own process env (not
// from web/.env.local) because those env vars are consumed by the
// desktop client at runtime, not by the web backend.
const DEFAULT_OLLAMA_URL = "http://localhost:11434";
const DEFAULT_OLLAMA_MODEL = "gemma4:e4b";

// Columns we expect to find on the `recordings` table. Keep in sync
// with supabase/migrations/*_create_recordings.sql.
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
// supabase/migrations/*_create_comments.sql.
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
// Every check is tagged with a "readiness track" so the final summary
// can tell you separately whether local development is usable and
// whether production deployment is usable. A user who only cares
// about production should still be able to look at the report and see
// exactly what's missing for prod, even if their local environment is
// deliberately unset.

type Track = "local" | "prod" | "both" | "neither";
type Status = "pass" | "fail" | "warn" | "skip";

interface CheckResult {
  name: string;
  status: Status;
  track: Track;
  message?: string;
}

const results: CheckResult[] = [];

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
 * Load both env files, bootstrapping either from its `.example`
 * template if it doesn't exist yet. A freshly-bootstrapped file will
 * have empty placeholder values, which makes the downstream checks
 * fail loudly with actionable messages — exactly what we want.
 */
async function loadEnvFiles(): Promise<{
  local: Record<string, string>;
  prod: Record<string, string>;
  bootstrapped: { local: boolean; prod: boolean };
}> {
  const bootstrapped = { local: false, prod: false };

  if (!existsSync(ENV_LOCAL_PATH)) {
    await copyFile(ENV_LOCAL_EXAMPLE_PATH, ENV_LOCAL_PATH);
    bootstrapped.local = true;
  }
  if (!existsSync(ENV_PROD_PATH)) {
    await copyFile(ENV_PROD_EXAMPLE_PATH, ENV_PROD_PATH);
    bootstrapped.prod = true;
  }

  const local = parseEnvFile(await readFile(ENV_LOCAL_PATH, "utf-8"));
  const prod = parseEnvFile(await readFile(ENV_PROD_PATH, "utf-8"));
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
  log("koom Doctor");
  log("───────────");

  const { local: env, prod: prodEnv, bootstrapped } = await loadEnvFiles();

  if (bootstrapped.local || bootstrapped.prod) {
    log("");
    log("Bootstrapped missing env files from their .example templates:");
    if (bootstrapped.local) log("  + web/.env.local");
    if (bootstrapped.prod) log("  + web/.env.prod.local");
    log("Fill in the placeholder values in each file before relying on the");
    log("readiness report below.");
  }

  // ── Section: Configuration (web/.env.local) ──────────────────────
  logSection("Configuration — web/.env.local (local development)");

  // R2 credentials are shared between local and prod — the same
  // bucket is hit by both the dev server and the production Vercel
  // deploy at koom's scale.
  for (const key of R2_REQUIRED_ENV_VARS) {
    if (env[key]) {
      pass(`${key} present`, "both");
    } else {
      fail(`${key} present`, "both", `Not set in web/.env.local`);
    }
  }

  // DATABASE_URL is strictly local-only in the new model. Production
  // Postgres is derived from the Supabase CLI link, not from this
  // file. Flag any attempt to point this value at a remote host.
  if (!env.DATABASE_URL) {
    fail(
      "DATABASE_URL present",
      "local",
      `Not set in web/.env.local. Expected the local Supabase stack URL:\n    postgresql://postgres:postgres@127.0.0.1:54322/postgres`,
    );
  } else if (!isLocalHost(env.DATABASE_URL)) {
    fail(
      "DATABASE_URL points at the local stack",
      "local",
      `DATABASE_URL in web/.env.local is pointed at a remote host. In koom's current configuration model, this file is LOCAL ONLY — production Postgres is derived from the Supabase CLI link (supabase/.temp/), not from DATABASE_URL. Set DATABASE_URL back to the local Supabase stack URL:\n    postgresql://postgres:postgres@127.0.0.1:54322/postgres`,
    );
  } else {
    pass("DATABASE_URL points at the local stack", "local");
  }

  // KOOM_PUBLIC_BASE_URL: local-only in this file. The production
  // value lives in Vercel's project environment variable settings.
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
      `KOOM_PUBLIC_BASE_URL in web/.env.local is ${env.KOOM_PUBLIC_BASE_URL}, which isn't localhost. This file is local-dev-only — set the production base URL in your Vercel project's environment variable settings instead. Fix by setting KOOM_PUBLIC_BASE_URL=http://localhost:3000 here.`,
    );
  } else {
    pass("KOOM_PUBLIC_BASE_URL points at the local dev server", "local");
  }

  // KOOM_ADMIN_SECRET is the same value in local and production, so
  // it's required on both tracks. Production deploys paste the same
  // value into Vercel env vars.
  if (env.KOOM_ADMIN_SECRET) {
    pass("KOOM_ADMIN_SECRET present", "both");
  } else {
    fail(
      "KOOM_ADMIN_SECRET present",
      "both",
      `Not set. The web app and desktop client both need this at runtime to authenticate admin actions. Generate one with:\n    openssl rand -hex 32`,
    );
  }

  // SUPABASE_DB_PASSWORD is only needed when pushing migrations to
  // the hosted Supabase project via the Supabase CLI. Purely a
  // production-track concern.
  if (env.SUPABASE_DB_PASSWORD) {
    pass("SUPABASE_DB_PASSWORD present", "prod");
  } else {
    warn(
      "SUPABASE_DB_PASSWORD present",
      "prod",
      `Not set. Needed by 'npm run db:push' and by the doctor's remote Postgres connectivity check. Find it at Supabase dashboard → Project Settings → Database → Database password.`,
    );
  }

  // ── Section: Configuration (web/.env.prod.local) ─────────────────
  logSection("Configuration — web/.env.prod.local (production deploy)");

  if (prodEnv.VERCEL_TOKEN) {
    pass("VERCEL_TOKEN present", "prod");
  } else {
    warn(
      "VERCEL_TOKEN present",
      "prod",
      `Not set in web/.env.prod.local. Mint a token at https://vercel.com/account/tokens so the doctor can verify your Vercel project is reachable. A future 'npm run vercel:sync' script will also use this to push production env vars into Vercel.`,
    );
  }

  if (prodEnv.VERCEL_PROJECT_ID) {
    pass("VERCEL_PROJECT_ID present", "prod");
  } else {
    warn(
      "VERCEL_PROJECT_ID present",
      "prod",
      `Not set in web/.env.prod.local. Find it at Vercel dashboard → koom project → Settings → General → Project ID (the 'prj_...' string, not the slug).`,
    );
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

  // ── Section: Postgres (local) ────────────────────────────────────
  logSection("Postgres (Supabase) — local stack");

  if (!env.DATABASE_URL || !isLocalHost(env.DATABASE_URL)) {
    skip(
      "Local Postgres connectivity",
      "local",
      "skipped because DATABASE_URL is missing or not pointed at the local stack",
    );
  } else {
    await runLocalPostgresChecks(env);
  }

  // ── Section: Postgres (remote, via Supabase CLI link) ────────────
  logSection("Postgres (Supabase) — remote, via supabase link");
  await runRemoteSupabaseChecks(env);

  // ── Section: Auto-title (Ollama) ──────────────────────────────────
  logSection("Auto-title (Ollama)");
  await runOllamaChecks();

  // ── Section: Desktop client (macOS) ───────────────────────────────
  logSection("Desktop client (macOS)");
  await runDesktopClientChecks();

  // ── Section: Vercel ───────────────────────────────────────────────
  logSection("Vercel");
  await runVercelChecks(prodEnv, env, SUPABASE_POOLER_URL_PATH);

  finish();
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
                `If you're targeting the local Supabase stack, make sure it's\n` +
                `running: 'npm run db:start'.`,
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
        checkTableColumns(client, "recordings", RECORDINGS_EXPECTED_COLUMNS),
    );
    if (!tableOk) return;

    // comments table exists with expected columns
    await runCheck("comments table exists with expected columns", track, () =>
      checkTableColumns(client, "comments", COMMENTS_EXPECTED_COLUMNS),
    );

    // commenters table exists with expected columns
    await runCheck("commenters table exists with expected columns", track, () =>
      checkTableColumns(client, "commenters", COMMENTERS_EXPECTED_COLUMNS),
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
async function checkTableColumns(
  client: pg.Client,
  tableName: string,
  expectedColumns: readonly string[],
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
      `No '${tableName}' table in the public schema.\n` +
        `Did you apply migrations? Try 'npm run db:reset'.`,
    );
  }
  const actual = rows.map((r) => r.column_name);
  const missing = expectedColumns.filter((c) => !actual.includes(c));
  if (missing.length > 0) {
    throw new Error(
      `Missing columns: ${missing.join(", ")}\n` +
        `Present columns: ${actual.join(", ")}\n` +
        `The migration in supabase/migrations/ may be out of sync\n` +
        `with the expected schema.`,
    );
  }
  return `(${rows.length} columns, all expected)`;
}

// ────────────────────────────────────────────────────────────────────
// Remote Supabase checks (via `supabase link` state)
// ────────────────────────────────────────────────────────────────────

/**
 * Verify that the Supabase CLI is installed, that `supabase link` has
 * been run at least once against a hosted project, and that the
 * resulting pooler URL + SUPABASE_DB_PASSWORD can actually connect to
 * the remote Postgres. We intentionally do NOT validate whether
 * migrations have been applied — per the doctor's contract, this
 * check is "do you have something you can migrate against?", not
 * "is your schema up to date?".
 */
async function runRemoteSupabaseChecks(
  env: Record<string, string>,
): Promise<void> {
  const track: Track = "prod";

  const linkExists = existsSync(SUPABASE_LINKED_PROJECT_PATH);
  const poolerUrlExists = existsSync(SUPABASE_POOLER_URL_PATH);

  if (!linkExists || !poolerUrlExists) {
    // Fast path failed. Before giving up, try to figure out WHY —
    // is the Supabase CLI itself missing, or is it installed but
    // not linked? This is the one place in the doctor where we
    // actually shell out to the CLI.
    const cliInstalled = await checkSupabaseCliInstalled();
    if (!cliInstalled) {
      fail(
        "Supabase CLI installed",
        track,
        `Could not invoke the Supabase CLI. koom uses 'npx -y ${SUPABASE_CLI_SPEC}' (same as the package.json scripts), so install Node.js + npm and rerun the doctor. If Node is already installed, try priming the CLI cache with:\n    npx -y ${SUPABASE_CLI_SPEC} --version`,
      );
      skip(
        "Supabase project linked",
        track,
        "skipped because the Supabase CLI is not usable",
      );
      return;
    }

    pass("Supabase CLI installed", track);
    fail(
      "Supabase project linked",
      track,
      `No linked project state found under supabase/.temp/. Authenticate and link your hosted Supabase project:\n    npx -y ${SUPABASE_CLI_SPEC} login\n    npx -y ${SUPABASE_CLI_SPEC} link --project-ref=<your-project-ref>\nYou'll find <your-project-ref> in the Supabase dashboard URL for your project.`,
    );
    return;
  }

  // Link state is present — the CLI must be installed and has been
  // used successfully at least once. Skip the explicit CLI version
  // shell-out as a performance optimization; linked-project.json
  // existing is proof enough.
  pass("Supabase CLI installed", track);

  // Read and parse the linked project metadata.
  let linkedProject: {
    name?: string;
    ref?: string;
    organization_slug?: string;
  };
  try {
    const raw = await readFile(SUPABASE_LINKED_PROJECT_PATH, "utf-8");
    linkedProject = JSON.parse(raw);
  } catch (err) {
    fail(
      "Supabase project linked",
      track,
      `Found ${SUPABASE_LINKED_PROJECT_PATH} but could not parse it: ${
        err instanceof Error ? err.message : String(err)
      }. Re-run 'npx -y ${SUPABASE_CLI_SPEC} link --project-ref=<ref>' to regenerate it.`,
    );
    return;
  }

  const friendly =
    linkedProject.name && linkedProject.ref
      ? `(project '${linkedProject.name}', ref ${linkedProject.ref}${
          linkedProject.organization_slug
            ? `, org ${linkedProject.organization_slug}`
            : ""
        })`
      : undefined;
  pass("Supabase project linked", track, friendly);

  // Now try to actually connect to the remote Postgres. We need both
  // the pooler URL (from the CLI link) and the password (from
  // .env.local). If the password isn't set, we can't make this call.
  if (!env.SUPABASE_DB_PASSWORD) {
    skip(
      "Remote Postgres reachable",
      track,
      "skipped because SUPABASE_DB_PASSWORD is not set in web/.env.local",
    );
    return;
  }

  let poolerUrl: string;
  try {
    poolerUrl = (await readFile(SUPABASE_POOLER_URL_PATH, "utf-8")).trim();
  } catch (err) {
    fail(
      "Remote Postgres reachable",
      track,
      `Could not read ${SUPABASE_POOLER_URL_PATH}: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
    return;
  }

  let parsed: URL;
  try {
    parsed = new URL(poolerUrl);
  } catch {
    fail(
      "Remote Postgres reachable",
      track,
      `${SUPABASE_POOLER_URL_PATH} did not contain a valid URL. Re-run 'supabase link' to regenerate it.`,
    );
    return;
  }

  await runCheck("Remote Postgres reachable", track, async () => {
    // Connect using the URL components pulled straight from the
    // Supabase CLI's cached pooler URL. We pass host/port/user
    // explicitly so there's no URL-encoding footgun with the
    // password, and we force SSL because the Supabase pooler always
    // requires it.
    const client = new PgClient({
      host: parsed.hostname,
      port: parsed.port ? parseInt(parsed.port, 10) : 5432,
      user: decodeURIComponent(parsed.username),
      password: env.SUPABASE_DB_PASSWORD,
      database: parsed.pathname.replace(/^\//, "") || "postgres",
      ssl: { rejectUnauthorized: false },
      connectionTimeoutMillis: 10_000,
    });
    try {
      await client.connect();
      const { rows } = await client.query<{ n: number }>("SELECT 1::int AS n");
      if (rows[0]?.n !== 1) {
        throw new Error(`Expected SELECT 1 to return 1, got ${rows[0]?.n}`);
      }
      return `(host ${parsed.hostname}, user ${parsed.username})`;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (msg.includes("password authentication failed")) {
        throw new Error(
          `Password authentication failed against the remote Supabase Postgres. Double-check SUPABASE_DB_PASSWORD in web/.env.local — it must match the password in Supabase dashboard → Project Settings → Database → Database password.`,
        );
      }
      throw err;
    } finally {
      try {
        await client.end();
      } catch {
        // ignore cleanup failures
      }
    }
  });
}

/**
 * Probe whether the Supabase CLI can be invoked via npx. Used only
 * when the faster "link state exists" check fails, so we can give
 * the user a precise "CLI missing" error vs a "CLI installed but
 * not linked" error. Runs with a 10s timeout — long enough for a
 * cold npx download but not so long that a broken install hangs the
 * doctor indefinitely.
 */
async function checkSupabaseCliInstalled(): Promise<boolean> {
  try {
    await execFileAsync("npx", ["-y", SUPABASE_CLI_SPEC, "--version"], {
      timeout: 10_000,
    });
    return true;
  } catch {
    return false;
  }
}

// ────────────────────────────────────────────────────────────────────
// Auto-title (Ollama) checks
// ────────────────────────────────────────────────────────────────────

/**
 * Verify the local Ollama server is reachable and that the model the
 * desktop client is configured to use for auto-titling has been
 * pulled. These checks are intentionally non-fatal: auto-titling is
 * a nice-to-have and the operator may deliberately run without it.
 * Failures here are reported as warnings, not errors, and the doctor
 * exits 0 as long as everything else passed.
 */
async function runOllamaChecks(): Promise<void> {
  // Ollama is only consulted by the desktop client during local
  // recording, so failures here only gate local-development readiness.
  // Production deployment does not run Ollama.
  const track: Track = "local";

  const enabledRaw = process.env.KOOM_AUTOTITLE_ENABLED ?? "true";
  const disabled = ["false", "0", "no", "off"].includes(
    enabledRaw.toLowerCase(),
  );
  if (disabled) {
    skip(
      "Ollama reachable",
      track,
      `KOOM_AUTOTITLE_ENABLED=${enabledRaw}; auto-title pipeline is disabled`,
    );
    return;
  }

  const ollamaUrlRaw = process.env.KOOM_OLLAMA_URL ?? DEFAULT_OLLAMA_URL;
  const ollamaModel = process.env.KOOM_OLLAMA_MODEL ?? DEFAULT_OLLAMA_MODEL;

  let ollamaUrl: URL;
  try {
    ollamaUrl = new URL(ollamaUrlRaw);
  } catch {
    warn(
      "Ollama reachable",
      track,
      `KOOM_OLLAMA_URL=${ollamaUrlRaw} is not a valid URL. The client will fall back to ${DEFAULT_OLLAMA_URL}.`,
    );
    return;
  }

  // Ollama exposes GET /api/tags — returns { models: [...] } and
  // only requires the server to be up. This is the cheapest way to
  // both check reachability and enumerate available models in one
  // round-trip.
  const tagsUrl = new URL("api/tags", ollamaUrl);
  let tagsJson: { models?: Array<{ name?: unknown }> };
  try {
    const res = await fetch(tagsUrl, {
      method: "GET",
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(3000),
    });
    if (!res.ok) {
      warn(
        "Ollama reachable",
        track,
        `GET ${tagsUrl.href} returned HTTP ${res.status}.\n` +
          `Start Ollama with 'ollama serve' (or the app) to enable auto-titling.`,
      );
      return;
    }
    tagsJson = (await res.json()) as typeof tagsJson;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    warn(
      "Ollama reachable",
      track,
      `Could not reach ${tagsUrl.href}: ${msg}\n` +
        `Start Ollama with 'ollama serve' (or the app) to enable auto-titling.\n` +
        `This check is non-fatal — the upload flow still works without it.`,
    );
    return;
  }

  pass("Ollama reachable", track, `(${ollamaUrl.origin})`);

  // Ollama model names can round-trip with or without the ":latest"
  // tag depending on how they were pulled, so accept either as a
  // match. Every other case is a real miss.
  const modelNames = (tagsJson.models ?? [])
    .map((m) => (typeof m.name === "string" ? m.name : null))
    .filter((n): n is string => n !== null);

  const hasModel =
    modelNames.includes(ollamaModel) ||
    modelNames.includes(`${ollamaModel}:latest`) ||
    (ollamaModel.endsWith(":latest") &&
      modelNames.includes(ollamaModel.slice(0, -":latest".length)));

  if (hasModel) {
    pass(`Ollama model '${ollamaModel}' is pulled`, track);
  } else {
    warn(
      `Ollama model '${ollamaModel}' is pulled`,
      track,
      `Model not found in /api/tags. Pull it with:\n` +
        `    ollama pull ${ollamaModel}\n` +
        `Known models: ${modelNames.length > 0 ? modelNames.join(", ") : "(none)"}`,
    );
  }
}

async function runDesktopClientChecks(): Promise<void> {
  // The desktop codesigning identity only matters for local
  // development builds — production deployment doesn't involve a
  // local Mac.
  const track: Track = "local";

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
        `    ./scripts/setup-dev-codesign.sh\n` +
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
        `    ./scripts/setup-dev-codesign.sh --force\n` +
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
// Vercel checks
// ────────────────────────────────────────────────────────────────────

/**
 * Runs two Vercel checks, both tagged prod-track:
 *
 *   1. "Vercel project reachable" — confirms VERCEL_TOKEN has access
 *      to VERCEL_PROJECT_ID via GET /v9/projects/{id}.
 *
 *   2. "Vercel env vars in sync" — delegates to computeSyncDiff() in
 *      scripts/lib/vercel-sync.ts and aggregates the per-variable
 *      results into a single doctor check. Pass when every expected
 *      variable is either in-sync or opaque (sensitive type, cannot
 *      verify). Warn with a count + hint to run `npm run vercel:sync`
 *      when any drift, missing, or unresolvable variable is
 *      detected. The drift check is skipped entirely when the
 *      reachability check fails, because there's nothing to compare
 *      against.
 */
async function runVercelChecks(
  prodEnv: Record<string, string>,
  localEnv: Record<string, string>,
  poolerUrlPath: string,
): Promise<void> {
  const track: Track = "prod";

  if (!prodEnv.VERCEL_TOKEN || !prodEnv.VERCEL_PROJECT_ID) {
    skip(
      "Vercel project reachable",
      track,
      `VERCEL_TOKEN / VERCEL_PROJECT_ID not set in web/.env.prod.local (optional — only needed if you want the doctor to verify your Vercel project is live and compare production env vars against the local sources of truth)`,
    );
    skip(
      "Vercel env vars in sync",
      track,
      "skipped because Vercel credentials are not configured",
    );
    return;
  }

  const reachable = await runVercelProjectReachableCheck(prodEnv);
  if (!reachable) {
    skip(
      "Vercel env vars in sync",
      track,
      "skipped because the Vercel project is not reachable",
    );
    return;
  }

  await runVercelEnvDriftCheck(prodEnv, localEnv, poolerUrlPath);
}

/**
 * Calls GET /v9/projects/{id} to verify the token/project combo.
 * Returns true on success so the caller knows whether to continue
 * with the drift check.
 */
async function runVercelProjectReachableCheck(
  prodEnv: Record<string, string>,
): Promise<boolean> {
  const track: Track = "prod";
  const projectUrl = new URL(
    `https://api.vercel.com/v9/projects/${encodeURIComponent(
      prodEnv.VERCEL_PROJECT_ID,
    )}`,
  );

  try {
    const res = await fetch(projectUrl, {
      headers: {
        Authorization: `Bearer ${prodEnv.VERCEL_TOKEN}`,
        Accept: "application/json",
      },
      signal: AbortSignal.timeout(10_000),
    });

    if (res.status === 401 || res.status === 403) {
      fail(
        "Vercel project reachable",
        track,
        `HTTP ${res.status} from Vercel API. The VERCEL_TOKEN does not have access to project '${prodEnv.VERCEL_PROJECT_ID}'. Re-mint a token at https://vercel.com/account/tokens with the right scope.`,
      );
      return false;
    }
    if (res.status === 404) {
      fail(
        "Vercel project reachable",
        track,
        `HTTP 404: project '${prodEnv.VERCEL_PROJECT_ID}' not found. Double-check VERCEL_PROJECT_ID in web/.env.prod.local — it's the project ID string (prj_...), not the project slug.`,
      );
      return false;
    }
    if (!res.ok) {
      fail(
        "Vercel project reachable",
        track,
        `HTTP ${res.status} from ${projectUrl.href}`,
      );
      return false;
    }

    const body = (await res.json()) as { name?: string };
    pass(
      "Vercel project reachable",
      track,
      body.name ? `(project '${body.name}')` : undefined,
    );
    return true;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    fail(
      "Vercel project reachable",
      track,
      `Could not reach ${projectUrl.href}: ${msg}`,
    );
    return false;
  }
}

/**
 * Aggregate drift check. Runs the same computeSyncDiff() that the
 * standalone vercel:sync CLI uses, then folds the per-variable
 * results into a single doctor check so the Vercel section stays
 * readable. The user can run `npm run vercel:sync` any time for the
 * full per-variable breakdown.
 */
async function runVercelEnvDriftCheck(
  prodEnv: Record<string, string>,
  localEnv: Record<string, string>,
  poolerUrlPath: string,
): Promise<void> {
  const track: Track = "prod";

  let diff;
  try {
    diff = await computeSyncDiff({
      vercelToken: prodEnv.VERCEL_TOKEN,
      vercelProjectId: prodEnv.VERCEL_PROJECT_ID,
      localEnv,
      poolerUrlPath,
    });
  } catch (err) {
    fail(
      "Vercel env vars in sync",
      track,
      `computeSyncDiff threw: ${err instanceof Error ? err.message : String(err)}`,
    );
    return;
  }

  if (diff.error) {
    fail("Vercel env vars in sync", track, diff.error);
    return;
  }

  const { summary } = diff;

  if (summary.allInSyncOrOpaque) {
    // Detail line tells the user how many variables were actually
    // verified vs how many are opaque so they don't mistake opaque
    // for "proven in sync."
    const opaqueNote =
      summary.opaque > 0
        ? `, ${summary.opaque} opaque (sensitive type, cannot verify)`
        : "";
    pass(
      "Vercel env vars in sync",
      track,
      `(${summary.inSync} verified${opaqueNote}${summary.unknown > 0 ? `, ${summary.unknown} extra on Vercel (ignored)` : ""})`,
    );
    return;
  }

  // Build a short warning message that names which variables need
  // attention without dumping the full report. `npm run vercel:sync`
  // is the place to get the full breakdown.
  const problems: string[] = [];
  if (summary.drift > 0) problems.push(`${summary.drift} drift`);
  if (summary.missing > 0) problems.push(`${summary.missing} missing`);
  if (summary.unresolvable > 0)
    problems.push(`${summary.unresolvable} unresolvable`);

  const affectedKeys = diff.results
    .filter(
      (r) =>
        r.status === "drift" ||
        r.status === "missing-on-vercel" ||
        r.status === "unresolvable",
    )
    .map((r) => r.key);

  warn(
    "Vercel env vars in sync",
    track,
    `${problems.join(", ")} detected: ${affectedKeys.join(", ")}.\n` +
      `Run 'npm run vercel:sync' for the full per-variable breakdown. The sync command is currently dry-run only; a future --write mode will apply the changes automatically.`,
  );
}

function finish(): never {
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

  reportTrack(
    "Local development",
    "You can develop and run the stack on this machine.",
    ["local", "both"],
  );
  log("");
  reportTrack(
    "Production deployment",
    "You can deploy the web app to Vercel against a hosted Postgres + R2.",
    ["prod", "both"],
  );
  log("");

  // Non-zero exit if *any* check failed, regardless of track. Warnings
  // don't fail the exit code.
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
  process.stderr.write(
    `\nUnexpected error: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}\n`,
  );
  process.exit(1);
});
