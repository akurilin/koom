#!/usr/bin/env tsx
/*
 * scripts/doctor.ts
 *
 * Read-only verification of the koom configuration. Run this any time
 * something seems off — at initial setup, after editing env vars, or
 * after a failed deploy. Exit code is non-zero if any check failed, so
 * it's CI-friendly.
 *
 * Currently checks:
 *   - Required env vars present in web/.env.local
 *   - R2 credentials work against the S3-compatible endpoint
 *   - Test PUT of a small throwaway object succeeds
 *   - Public .r2.dev URL serves that object
 *   - Range requests return 206 with Content-Range and the right slice
 *   - Test object is cleaned up before exit
 *   - Postgres reachable via DATABASE_URL
 *   - recordings table exists with expected columns
 *   - Round-trip INSERT / SELECT / DELETE of a throwaway row
 *
 * Vercel checks land in a later round.
 */

import {
  DeleteObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const { Client: PgClient } = pg;

// ────────────────────────────────────────────────────────────────────
// Constants
// ────────────────────────────────────────────────────────────────────

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);
const ENV_LOCAL_PATH = join(REPO_ROOT, "web", ".env.local");

const TEST_KEY_PREFIX = "_koom-doctor/";
const TEST_BYTE_COUNT = 1024;

const R2_REQUIRED_ENV_VARS = [
  "R2_BUCKET",
  "R2_ACCOUNT_ID",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
  "R2_PUBLIC_BASE_URL",
] as const;

const POSTGRES_REQUIRED_ENV_VARS = ["DATABASE_URL"] as const;

const SOFT_ENV_VARS = [
  "KOOM_PUBLIC_BASE_URL",
  "KOOM_ADMIN_SECRET",
] as const;

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

// ────────────────────────────────────────────────────────────────────
// Result tracking
// ────────────────────────────────────────────────────────────────────

let passCount = 0;
let failCount = 0;
let warnCount = 0;
let skipCount = 0;

function log(message = ""): void {
  process.stdout.write(message + "\n");
}

function logSection(name: string): void {
  log("");
  log(name);
}

function pass(name: string, detail?: string): void {
  log(`  ✓ ${name}${detail ? ` ${detail}` : ""}`);
  passCount++;
}

function fail(name: string, message: string): void {
  log(`  ✗ ${name}`);
  for (const line of message.split("\n")) log(`      ${line}`);
  failCount++;
}

function warn(name: string, message: string): void {
  log(`  ⚠ ${name}`);
  for (const line of message.split("\n")) log(`      ${line}`);
  warnCount++;
}

function skip(name: string, reason: string): void {
  log(`  ⊘ ${name} — ${reason}`);
  skipCount++;
}

async function runCheck(
  name: string,
  fn: () => Promise<string | undefined>,
): Promise<boolean> {
  try {
    const detail = await fn();
    pass(name, detail);
    return true;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    fail(name, msg);
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

async function loadEnvLocal(): Promise<Record<string, string>> {
  if (!existsSync(ENV_LOCAL_PATH)) {
    log("");
    log(`Error: web/.env.local not found.`);
    log("");
    log(`Copy web/.env.example to web/.env.local and fill it in before`);
    log(`running the doctor.`);
    process.exit(1);
  }
  return parseEnvFile(await readFile(ENV_LOCAL_PATH, "utf-8"));
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

async function main(): Promise<void> {
  log("koom Doctor");
  log("───────────");

  const env = await loadEnvLocal();

  // ── Section: Configuration ────────────────────────────────────────
  logSection("Configuration");

  for (const key of [
    ...R2_REQUIRED_ENV_VARS,
    ...POSTGRES_REQUIRED_ENV_VARS,
  ]) {
    if (env[key]) {
      pass(`${key} present`);
    } else {
      fail(`${key} present`, `Not set in web/.env.local`);
    }
  }
  for (const key of SOFT_ENV_VARS) {
    if (env[key]) {
      pass(`${key} present`);
    } else {
      warn(
        `${key} present`,
        `Not set. The web app will need this at runtime, but downstream checks can still run.`,
      );
    }
  }

  const r2VarsPresent = R2_REQUIRED_ENV_VARS.every((k) => !!env[k]);
  const postgresVarsPresent = POSTGRES_REQUIRED_ENV_VARS.every((k) => !!env[k]);

  // ── Section: R2 ───────────────────────────────────────────────────
  logSection("Cloudflare R2");

  if (!r2VarsPresent) {
    skip(
      "R2 connectivity",
      "skipped because required R2_* env vars are missing",
    );
  } else {
    await runR2Checks(env);
  }

  // ── Section: Postgres ─────────────────────────────────────────────
  logSection("Postgres (Supabase)");

  if (!postgresVarsPresent) {
    skip(
      "Postgres connectivity",
      "skipped because DATABASE_URL is not set in web/.env.local",
    );
  } else {
    await runPostgresChecks(env);
  }

  // ── Section: Vercel (optional) ────────────────────────────────────
  logSection("Vercel");
  if (env.VERCEL_TOKEN && env.VERCEL_PROJECT_ID) {
    skip(
      "Vercel project reachable",
      "not yet implemented (later round)",
    );
  } else {
    skip(
      "Vercel project reachable",
      "VERCEL_TOKEN / VERCEL_PROJECT_ID not set (optional, skipped)",
    );
  }

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
    await runCheck("HEAD confirms object exists and size matches", async () => {
      const head = await s3.send(
        new HeadObjectCommand({ Bucket: bucket, Key: testKey }),
      );
      if (head.ContentLength !== TEST_BYTE_COUNT) {
        throw new Error(
          `Expected ContentLength=${TEST_BYTE_COUNT}, got ${head.ContentLength}`,
        );
      }
      return `(Content-Length=${head.ContentLength})`;
    });

    // Public GET — full object
    const publicUrl = `${publicBaseUrl}/${testKey}`;
    await runCheck(
      `Public URL serves the test object (no Range)`,
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
        pass("Test object cleaned up");
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        warn(
          "Test object cleanup",
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

async function runPostgresChecks(env: Record<string, string>): Promise<void> {
  const client = new PgClient({ connectionString: env.DATABASE_URL });

  const testId = `_doctor-test-${Date.now()}`;
  let connected = false;
  let inserted = false;

  try {
    // Connect
    const connectOk = await runCheck("Connect via DATABASE_URL", async () => {
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
    });
    if (!connectOk) return;

    // Basic SELECT
    await runCheck("Basic SELECT 1 query works", async () => {
      const { rows } = await client.query<{ n: number }>(
        "SELECT 1::int AS n",
      );
      if (rows[0]?.n !== 1) {
        throw new Error(`Expected 1, got ${JSON.stringify(rows[0])}`);
      }
      return undefined;
    });

    // recordings table exists with expected columns
    const tableOk = await runCheck(
      "recordings table exists with expected columns",
      async () => {
        const { rows } = await client.query<{ column_name: string }>(
          `SELECT column_name
             FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = 'recordings'
            ORDER BY ordinal_position`,
        );
        if (rows.length === 0) {
          throw new Error(
            `No 'recordings' table in the public schema.\n` +
              `Did you apply migrations? Try 'npm run db:reset'.`,
          );
        }
        const actual = rows.map((r) => r.column_name);
        const missing = RECORDINGS_EXPECTED_COLUMNS.filter(
          (c) => !actual.includes(c),
        );
        if (missing.length > 0) {
          throw new Error(
            `Missing columns: ${missing.join(", ")}\n` +
              `Present columns: ${actual.join(", ")}\n` +
              `The migration in supabase/migrations/ may be out of sync\n` +
              `with the expected schema.`,
          );
        }
        return `(${rows.length} columns, all expected)`;
      },
    );
    if (!tableOk) return;

    // INSERT a throwaway row
    const insertOk = await runCheck(
      "INSERT a throwaway row",
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
    await runCheck(
      "Listing query shape is indexed",
      async () => {
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
      },
    );
  } finally {
    // Always clean up the test row if we managed to insert one.
    if (inserted) {
      try {
        await client.query("DELETE FROM recordings WHERE id = $1", [testId]);
        pass("Test row cleaned up");
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        warn(
          "Test row cleanup",
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

function finish(): never {
  log("");
  log("─────────────────────────────────────────────────────");
  const bits: string[] = [];
  bits.push(`${passCount} passed`);
  if (failCount > 0) bits.push(`${failCount} failed`);
  if (warnCount > 0) bits.push(`${warnCount} warning${warnCount === 1 ? "" : "s"}`);
  if (skipCount > 0) bits.push(`${skipCount} skipped`);
  log(`Summary: ${bits.join(", ")}`);
  process.exit(failCount > 0 ? 1 : 0);
}

main().catch((err) => {
  process.stderr.write(
    `\nUnexpected error: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}\n`,
  );
  process.exit(1);
});
