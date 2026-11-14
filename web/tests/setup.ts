/**
 * Vitest global setup. Runs once before the test files are loaded
 * so `process.env` is populated by the time any route handler module
 * gets imported.
 *
 * Loads `web/.env.test.local` (NOT `web/.env.local`) so every
 * integration test runs against the isolated Cloudflare R2 test
 * bucket (koom-recordings-test) rather than production. This gives
 * the same environment isolation Playwright will use in the E2E
 * round and means a test bug cannot wipe production data.
 *
 * The env file is created + populated by `npm run r2:setup:test`.
 * If it's missing when tests start, we error loudly with a pointer
 * to that script rather than silently falling back to something
 * else.
 *
 * We don't use `@next/env` here: in the Vitest context it doesn't
 * reliably mutate `process.env` before the test modules run. A tiny
 * hand-rolled parser is both simpler and matches the pattern our
 * operator scripts (scripts/r2-setup.ts, scripts/doctor.ts) already
 * use.
 */

import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const thisDir = resolve(fileURLToPath(import.meta.url), "..");
const envTestLocalPath = resolve(thisDir, "..", ".env.test.local");

if (!existsSync(envTestLocalPath)) {
  throw new Error(
    `web/.env.test.local not found at ${envTestLocalPath}.\n\n` +
      `Tests run against an isolated Cloudflare R2 test bucket\n` +
      `(koom-recordings-test) to avoid any risk of modifying production\n` +
      `data. Before running tests, create the test bucket and populate\n` +
      `the credentials file by running:\n\n` +
      `    npm run r2:setup:test\n\n` +
      `This is a one-time setup. It's idempotent and can be re-run\n` +
      `safely if you ever need to refresh the test credentials.`,
  );
}

const content = readFileSync(envTestLocalPath, "utf-8");

for (const rawLine of content.split("\n")) {
  const line = rawLine.trim();
  if (!line || line.startsWith("#")) continue;

  const eq = line.indexOf("=");
  if (eq < 0) continue;

  const key = line.slice(0, eq).trim();
  let value = line.slice(eq + 1).trim();

  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    value = value.slice(1, -1);
  }

  // Don't override values already set in the shell env — lets a
  // developer experiment with `KOOM_ADMIN_EMAILS=foo npm test` if
  // they want, without this setup file clobbering it.
  if (!(key in process.env)) {
    process.env[key] = value;
  }
}

// ── Test device token ────────────────────────────────────────────
// Admin route tests authenticate the way the desktop app does: with
// a device token as `Authorization: Bearer`. Register the fixed
// KOOM_TEST_DEVICE_TOKEN from .env.test.local (idempotently) so those
// tests have a valid credential, owned by the first allowlisted
// KOOM_ADMIN_EMAILS address.
{
  const { getDb } = await import("@/lib/db/client");
  const { hashDeviceToken } = await import("@/lib/auth/device-tokens");
  const { adminEmailAllowlist } = await import("@/lib/auth/config");

  const token = process.env.KOOM_TEST_DEVICE_TOKEN;
  const email = adminEmailAllowlist()[0];
  if (!token || !email) {
    throw new Error(
      "web/.env.test.local must set KOOM_TEST_DEVICE_TOKEN and KOOM_ADMIN_EMAILS. Delete the file and rerun `npm run r2:setup:test` to regenerate it.",
    );
  }
  await getDb().query(
    `INSERT INTO device_tokens (id, token_hash, email, label)
     VALUES ('vitest-device', $1, $2, 'vitest')
     ON CONFLICT (id) DO UPDATE
        SET token_hash = EXCLUDED.token_hash, email = EXCLUDED.email`,
    [hashDeviceToken(token), email],
  );
}
