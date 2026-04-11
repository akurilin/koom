/**
 * Boot-time sanity checks for the koom web backend.
 *
 * Runs once from instrumentation.ts when the Next.js server starts.
 * Verifies that every external dependency the app needs to operate
 * is actually reachable before the first request arrives. If any
 * check fails, we print a clear, actionable error block to stderr
 * and exit(1) so the developer sees exactly what's wrong instead of
 * getting a cryptic ECONNREFUSED on the first query five minutes
 * later.
 *
 * This is deliberately narrower than `npm run doctor`:
 *
 *   - doctor is an on-demand, read-write diagnostic that PUTs test
 *     objects, round-trips a test row through the recordings table,
 *     and probes Ollama.
 *   - preflight is a read-only, fast connectivity probe intended to
 *     run on every server start in dev without being annoying.
 *
 * Only runs in development (NODE_ENV=development). Production cold
 * starts shouldn't crash on a transient DB hiccup — the platform
 * handles retries and the route handlers already report 500s with
 * structured errors on their own.
 */

import { HeadBucketCommand, S3Client } from "@aws-sdk/client-s3";
import pg from "pg";

const BANNER = "━".repeat(64);

const REQUIRED_ENV_VARS = [
  "DATABASE_URL",
  "R2_BUCKET",
  "R2_ACCOUNT_ID",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
  "R2_PUBLIC_BASE_URL",
  "KOOM_ADMIN_SECRET",
] as const;

interface PreflightError {
  check: string;
  message: string;
  fix: string;
}

export async function runPreflight(): Promise<void> {
  const errors: PreflightError[] = [];

  // ── 1. Required env vars ────────────────────────────────────────
  const missing = REQUIRED_ENV_VARS.filter((k) => !process.env[k]);
  if (missing.length > 0) {
    errors.push({
      check: "Environment variables",
      message: `Missing: ${missing.join(", ")}`,
      fix: "Copy web/.env.example to web/.env.local and fill in the values.",
    });
  }

  // ── 2. Postgres reachable ───────────────────────────────────────
  if (process.env.DATABASE_URL) {
    const pgError = await checkPostgres(process.env.DATABASE_URL);
    if (pgError) errors.push(pgError);
  }

  // ── 3. Cloudflare R2 reachable ──────────────────────────────────
  const r2Ready =
    !!process.env.R2_BUCKET &&
    !!process.env.R2_ACCOUNT_ID &&
    !!process.env.R2_ACCESS_KEY_ID &&
    !!process.env.R2_SECRET_ACCESS_KEY;
  if (r2Ready) {
    const r2Error = await checkR2();
    if (r2Error) errors.push(r2Error);
  }

  if (errors.length === 0) {
    console.log(
      `\n${BANNER}\n[koom preflight] All checks passed — server is ready.\n${BANNER}\n`,
    );
    return;
  }

  // Print every error in one block so the developer sees the full
  // picture, not just the first thing that tripped.
  const lines: string[] = [];
  lines.push("");
  lines.push(BANNER);
  lines.push("[koom preflight] STARTUP CHECKS FAILED");
  lines.push(BANNER);
  for (const [i, err] of errors.entries()) {
    lines.push("");
    lines.push(`(${i + 1}) ${err.check}`);
    for (const line of err.message.split("\n")) {
      lines.push(`    ${line}`);
    }
    lines.push("");
    lines.push(`    Fix:`);
    for (const line of err.fix.split("\n")) {
      lines.push(`      ${line}`);
    }
  }
  lines.push("");
  lines.push(BANNER);
  lines.push("Run `npm run doctor` for a more thorough diagnostic.");
  lines.push(BANNER);
  lines.push("");

  console.error(lines.join("\n"));

  // Let stderr flush before the process dies so the message isn't
  // lost on a fast exit.
  await new Promise((resolve) => setTimeout(resolve, 100));
  process.exit(1);
}

async function checkPostgres(
  connectionString: string,
): Promise<PreflightError | null> {
  const isLocal =
    connectionString.includes("localhost") ||
    connectionString.includes("127.0.0.1");

  const client = new pg.Client({
    connectionString,
    ssl: isLocal ? undefined : { rejectUnauthorized: false },
    connectionTimeoutMillis: 5000,
  });

  try {
    await client.connect();
    await client.query("SELECT 1");
    await client.end();
    return null;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    let fix = "Check DATABASE_URL in web/.env.local.";
    if (msg.includes("ECONNREFUSED")) {
      fix = isLocal
        ? "Postgres is not running. If you use the local Supabase stack,\n" +
          "make sure Docker is running and start it with:\n" +
          "    npm run db:start"
        : "The database server refused the connection. Check that the\n" +
          "host and port in DATABASE_URL are correct and reachable.";
    } else if (msg.includes("ENOTFOUND") || msg.includes("EAI_AGAIN")) {
      fix =
        "The database hostname could not be resolved. Check DATABASE_URL\n" +
        "in web/.env.local for typos.";
    } else if (msg.includes("password authentication failed")) {
      fix =
        "Credentials in DATABASE_URL were rejected. Verify the username\n" +
        "and password in web/.env.local.";
    }
    // Best-effort cleanup; ignore failures.
    try {
      await client.end();
    } catch {
      // no-op
    }
    return {
      check: "Postgres (DATABASE_URL)",
      message: msg,
      fix,
    };
  }
}

async function checkR2(): Promise<PreflightError | null> {
  const s3 = new S3Client({
    region: "auto",
    endpoint: `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: process.env.R2_ACCESS_KEY_ID!,
      secretAccessKey: process.env.R2_SECRET_ACCESS_KEY!,
    },
    requestHandler: {
      requestTimeout: 5000,
      connectionTimeout: 5000,
    },
  });

  try {
    await s3.send(new HeadBucketCommand({ Bucket: process.env.R2_BUCKET! }));
    return null;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    let fix =
      "Check R2_* values in web/.env.local, or re-run:\n" +
      "    npm run r2:setup";
    if (msg.includes("NotFound") || msg.includes("NoSuchBucket")) {
      fix =
        `Bucket '${process.env.R2_BUCKET}' does not exist in this Cloudflare\n` +
        `account. Create it or fix R2_BUCKET in web/.env.local.`;
    } else if (
      msg.includes("InvalidAccessKeyId") ||
      msg.includes("SignatureDoesNotMatch")
    ) {
      fix =
        "R2 credentials were rejected. Verify R2_ACCESS_KEY_ID and\n" +
        "R2_SECRET_ACCESS_KEY in web/.env.local.";
    }
    return {
      check: "Cloudflare R2 (HeadBucket)",
      message: msg,
      fix,
    };
  }
}
