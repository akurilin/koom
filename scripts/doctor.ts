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
 *
 * Postgres and Vercel checks land in subsequent rounds and are
 * intentionally marked "skipped — not yet implemented" for now.
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

// ────────────────────────────────────────────────────────────────────
// Constants
// ────────────────────────────────────────────────────────────────────

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);
const ENV_LOCAL_PATH = join(REPO_ROOT, "web", ".env.local");

const TEST_KEY_PREFIX = "_koom-doctor/";
const TEST_BYTE_COUNT = 1024;

const REQUIRED_ENV_VARS = [
  "R2_BUCKET",
  "R2_ACCOUNT_ID",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
  "R2_PUBLIC_BASE_URL",
] as const;

const SOFT_ENV_VARS = [
  "KOOM_PUBLIC_BASE_URL",
  "KOOM_ADMIN_SECRET",
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

  let envOk = true;
  for (const key of REQUIRED_ENV_VARS) {
    if (env[key]) {
      pass(`${key} present`);
    } else {
      fail(`${key} present`, `Not set in web/.env.local`);
      envOk = false;
    }
  }
  for (const key of SOFT_ENV_VARS) {
    if (env[key]) {
      pass(`${key} present`);
    } else {
      warn(
        `${key} present`,
        `Not set. The web app will need this at runtime, but R2 checks below can still run.`,
      );
    }
  }

  // ── Section: R2 ───────────────────────────────────────────────────
  logSection("Cloudflare R2");

  if (!envOk) {
    skip(
      "R2 connectivity",
      "skipped because required R2_* env vars are missing",
    );
    finish();
    return;
  }

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
      // Cannot meaningfully run downstream checks without a put.
      finish();
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

  // ── Section: Postgres ─────────────────────────────────────────────
  logSection("Postgres (Supabase)");
  skip("DATABASE_URL connectivity", "not yet implemented (next round)");
  skip("recordings table present", "not yet implemented (next round)");

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
