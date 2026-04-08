/**
 * Playwright config for koom's E2E suite.
 *
 * What this config wires up:
 *
 *   1. Loads `web/.env.test.local` via dotenv at config-import
 *      time so KOOM_ADMIN_SECRET, R2_BUCKET, DATABASE_URL, etc.
 *      are present in `process.env` before anything else runs.
 *      The Playwright-managed Next.js child process inherits
 *      these via env inheritance.
 *
 *   2. Starts `next dev` on a non-standard port (default 3456,
 *      overridable via KOOM_TEST_PORT) so the test server doesn't
 *      collide with a regular `npm run dev` instance the
 *      developer might already have running.
 *
 *   3. Points `baseURL` at the same port so test code can use
 *      `await page.goto('/app/recordings')` without hardcoding
 *      the host.
 *
 * Why we deliberately do not split tests across multiple workers:
 * the seeded test data (Postgres rows + R2 objects) is shared
 * mutable state, and parallel runs would race on insert/delete.
 * The test suite is small enough (one happy-path test today)
 * that fully serial execution is fine.
 */

import path from "node:path";

import { defineConfig } from "@playwright/test";
import dotenv from "dotenv";

const envPath = path.resolve(__dirname, ".env.test.local");
const envResult = dotenv.config({ path: envPath });
if (envResult.error) {
  throw new Error(
    `web/.env.test.local is missing or unreadable.\n\n` +
      `E2E tests require an isolated R2 test bucket. Run:\n\n` +
      `    npm run r2:setup:test\n\n` +
      `to create the bucket and populate the credentials file.`,
  );
}

const TEST_PORT = process.env.KOOM_TEST_PORT ?? "3456";
const BASE_URL = `http://localhost:${TEST_PORT}`;

export default defineConfig({
  testDir: "./tests/e2e",
  globalSetup: path.resolve(__dirname, "tests/e2e/global-setup.ts"),
  timeout: 60_000,
  expect: {
    timeout: 10_000,
  },
  // Shared mutable state (real Postgres rows, real R2 objects).
  // Parallel runs would race; keep it serial for now.
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "list" : "list",
  use: {
    baseURL: BASE_URL,
    // Capture diagnostics on failure so debugging is bearable.
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
  webServer: {
    command: `npx next dev -p ${TEST_PORT}`,
    url: BASE_URL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    // Inherit the parent process env (including the dotenv-loaded
    // test variables) so the child Next.js process sees R2 test
    // bucket credentials, the local Supabase URL, the fake admin
    // secret, etc. Next.js's own .env.local loading respects
    // already-set env vars, so this wins over web/.env.local.
    env: {
      ...process.env,
      PORT: TEST_PORT,
    },
  },
});
