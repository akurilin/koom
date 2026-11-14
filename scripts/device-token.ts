#!/usr/bin/env tsx
/*
 * scripts/device-token.ts
 *
 * Mint a desktop device token without the interactive Google sign-in,
 * for unattended (agentic) runs of the koom app. The token is inserted
 * directly into the target database and written to the plaintext
 * credentials file the app reads when KOOM_DEVICE_CREDENTIALS_FILE is
 * set — the same file `npm run app:run:prod` points at.
 *
 * Usage:
 *
 *   npm run device:token                 # dev: local Docker Postgres
 *   npm run device:token -- --env prod   # prod: RENDER_DATABASE_URL
 *
 * Options:
 *   --env dev|prod   Which koom environment/database (default: dev)
 *   --label <name>   Device label stored with the token
 *   --file <path>    Credentials file (default:
 *                    ~/.config/koom/device-credentials.json)
 *
 * The token belongs to the first address in KOOM_ADMIN_EMAILS from
 * web/.env.local, so it stops working if that address is removed from
 * the deployment's allowlist. Revoke it like any device: delete its
 * row from device_tokens.
 */

import { createHash, randomBytes, randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir, hostname } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import pg from "pg";

const REPO_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

function parseEnvFile(content: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 0) continue;
    let value = trimmed.slice(eq + 1).trim();
    if (/^(["']).*\1$/.test(value)) value = value.slice(1, -1);
    result[trimmed.slice(0, eq).trim()] = value;
  }
  return result;
}

async function loadEnv(name: string): Promise<Record<string, string>> {
  const path = join(REPO_ROOT, "web", name);
  return existsSync(path) ? parseEnvFile(await readFile(path, "utf-8")) : {};
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      env: { type: "string", default: "dev" },
      label: { type: "string", default: `agent on ${hostname()}` },
      file: {
        type: "string",
        default: join(homedir(), ".config", "koom", "device-credentials.json"),
      },
    },
  });
  const environment = values.env;
  if (environment !== "dev" && environment !== "prod") {
    throw new Error("--env must be 'dev' or 'prod'");
  }

  const localEnv = await loadEnv(".env.local");
  const email = (localEnv.KOOM_ADMIN_EMAILS ?? "")
    .split(",")[0]
    ?.trim()
    .toLowerCase();
  if (!email) throw new Error("KOOM_ADMIN_EMAILS is not set in web/.env.local");

  const connectionString =
    environment === "dev"
      ? localEnv.DATABASE_URL
      : (await loadEnv(".env.prod.local")).RENDER_DATABASE_URL;
  if (!connectionString) {
    throw new Error(
      environment === "dev"
        ? "DATABASE_URL is not set in web/.env.local"
        : "RENDER_DATABASE_URL is not set in web/.env.prod.local",
    );
  }

  // Same format and hashing as web/lib/auth/device-tokens.ts.
  const token = `koom_dt_${randomBytes(32).toString("base64url")}`;
  const client = new pg.Client({
    connectionString,
    ssl: environment === "prod" ? { rejectUnauthorized: false } : undefined,
  });
  await client.connect();
  try {
    await client.query(
      `INSERT INTO device_tokens (id, token_hash, email, label)
       VALUES ($1, $2, $3, $4)`,
      [
        randomUUID(),
        createHash("sha256").update(token).digest("hex"),
        email,
        values.label,
      ],
    );
  } finally {
    await client.end();
  }

  const file = resolve(values.file);
  const credentials = existsSync(file)
    ? (JSON.parse(await readFile(file, "utf-8")) as Record<string, unknown>)
    : {};
  credentials[environment] = { token, email };
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, JSON.stringify(credentials, null, 2) + "\n");
  await chmod(file, 0o600);

  console.log(
    `Minted a ${environment} device token for ${email} ("${values.label}") and wrote it to ${file}.`,
  );
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
