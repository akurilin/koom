#!/usr/bin/env tsx
/*
 * scripts/r2-setup.ts
 *
 * Provisions or reconciles the production Cloudflare R2 bucket used
 * by the koom web app. Thin wrapper around the shared provisioning
 * logic in scripts/lib/r2-provision.ts.
 *
 * Reads CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID from
 * web/.env.local, creates/reuses the `koom-recordings` bucket,
 * applies CORS, enables the managed .r2.dev public URL, mints an
 * R2 S3-compatible API token, and writes the resulting R2_* values
 * back into web/.env.local.
 *
 * State is tracked in scripts/.r2-state.json.
 *
 * The test equivalent is scripts/r2-setup-test.ts, which targets a
 * separate `koom-recordings-test` bucket with its own credentials,
 * state file, and output env file — so Playwright runs can't
 * accidentally stomp on production data.
 */

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { provisionR2 } from "./lib/r2-provision";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);

provisionR2({
  displayName: "koom R2 Setup",
  bucketName: "koom-recordings",
  runtimeTokenName: "koom-runtime-r2",
  stateFilePath: join(SCRIPT_DIR, ".r2-state.json"),
  credentialsEnvPath: join(REPO_ROOT, "web", ".env.local"),
  outputEnvPath: join(REPO_ROOT, "web", ".env.local"),
}).catch((err) => {
  process.stderr.write(
    `\nUnexpected error: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}\n`,
  );
  process.exit(1);
});
