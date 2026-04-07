/**
 * Vitest global setup. Runs once before the test files are loaded
 * so `process.env` is populated by the time any route handler module
 * gets imported.
 *
 * We don't use `@next/env` here: in the Vitest context it doesn't
 * reliably mutate `process.env` before the test modules run. A tiny
 * hand-rolled parser is both simpler and matches the pattern our
 * operator scripts (scripts/r2-setup.ts, scripts/doctor.ts) already
 * use.
 */

import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const thisDir = resolve(fileURLToPath(import.meta.url), "..");
const envLocalPath = resolve(thisDir, "..", ".env.local");

if (!existsSync(envLocalPath)) {
  throw new Error(
    `web/.env.local not found at ${envLocalPath}. ` +
      `Tests need real credentials — copy web/.env.example to web/.env.local ` +
      `and fill it in, then re-run.`,
  );
}

const content = readFileSync(envLocalPath, "utf-8");

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
  // developer experiment with `KOOM_ADMIN_SECRET=foo npm test` if
  // they want, without this setup file clobbering it.
  if (!(key in process.env)) {
    process.env[key] = value;
  }
}
