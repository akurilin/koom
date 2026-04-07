#!/usr/bin/env tsx
/*
 * scripts/r2-setup.ts
 *
 * Provisions or reconciles a Cloudflare R2 bucket for koom.
 *
 * Reads CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID from
 * web/.env.local. Creates the bucket if missing, applies CORS, enables
 * the managed .r2.dev public URL, mints an R2 S3-compatible API token
 * scoped to that bucket, derives the S3 secret access key, and writes
 * the resulting R2_* values back into web/.env.local.
 *
 * State is tracked in scripts/.r2-state.json. On re-run, the script
 * reads state, verifies each tracked resource still exists, and skips
 * work that is already done. Pre-existing resources where
 * `createdByKoom` is false are never modified.
 */

import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { stdin as input, stdout as output } from "node:process";
import * as readline from "node:readline/promises";
import { fileURLToPath } from "node:url";

// ────────────────────────────────────────────────────────────────────
// Constants
// ────────────────────────────────────────────────────────────────────

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);
const ENV_LOCAL_PATH = join(REPO_ROOT, "web", ".env.local");
const ENV_EXAMPLE_PATH = join(REPO_ROOT, "web", ".env.example");
const STATE_PATH = join(SCRIPT_DIR, ".r2-state.json");

const BUCKET_NAME = "koom-recordings";
const RUNTIME_TOKEN_NAME = "koom-runtime-r2";
const CF_API_BASE = "https://api.cloudflare.com/client/v4";

// CORS rules sent via the Cloudflare REST API. Field names are camelCase
// here, NOT the AllowedMethods/AllowedOrigins style used by the S3 XML
// API. The desktop client never enforces CORS (it's a native HTTP
// client), but a browser-based admin upload page would, and allowing
// PUT/HEAD/GET from any origin keeps both paths working without making
// the script jurisdiction-aware.
const CORS_RULES = {
  rules: [
    {
      allowed: {
        origins: ["*"],
        methods: ["GET", "PUT", "HEAD"],
        headers: ["*"],
      },
      exposeHeaders: ["ETag"],
      maxAgeSeconds: 3600,
    },
  ],
};

// Permission group names looked up at runtime — Cloudflare's UUIDs for
// these vary by account type, so hardcoding them is not safe. The names
// are stable.
const REQUIRED_PERMISSION_GROUPS = [
  "Workers R2 Storage Bucket Item Write",
  "Workers R2 Storage Bucket Item Read",
] as const;

// ────────────────────────────────────────────────────────────────────
// Types
// ────────────────────────────────────────────────────────────────────

interface State {
  version: 1;
  cloudflare: {
    accountId: string;
    bucket?: {
      name: string;
      createdByKoom: boolean;
      createdAt: string;
    };
    cors?: {
      appliedByKoom: boolean;
      rulesHash: string;
      appliedAt: string;
    };
    publicAccess?: {
      enabledByKoom: boolean;
      publicBaseUrl: string;
      enabledAt: string;
    };
    s3Token?: {
      id: string;
      createdByKoom: boolean;
      createdAt: string;
    };
  };
}

interface CloudflareEnvelope<T> {
  success: boolean;
  errors?: Array<{ code: number; message: string }>;
  messages?: unknown[];
  result: T;
}

interface BucketInfo {
  name: string;
  creation_date?: string;
  location?: string;
  storage_class?: string;
}

interface ManagedDomainResult {
  bucketId?: string;
  domain: string;
  enabled: boolean;
}

interface PermissionGroup {
  id: string;
  name: string;
  scopes?: string[];
}

interface CreatedToken {
  id: string;
  value: string;
  name: string;
  status: string;
}

// ────────────────────────────────────────────────────────────────────
// Logging helpers
// ────────────────────────────────────────────────────────────────────

function log(message = ""): void {
  process.stdout.write(message + "\n");
}

function logSuccess(message: string): void {
  process.stdout.write(`  ✓ ${message}\n`);
}

function logWarn(message: string): void {
  process.stdout.write(`  ⚠ ${message}\n`);
}

function fail(message: string): never {
  process.stderr.write(`\nError: ${message}\n`);
  process.exit(1);
}

async function prompt(question: string): Promise<string> {
  const rl = readline.createInterface({ input, output });
  try {
    return await rl.question(question);
  } finally {
    rl.close();
  }
}

async function confirm(question: string, defaultYes = false): Promise<boolean> {
  const suffix = defaultYes ? " [Y/n] " : " [y/N] ";
  const answer = (await prompt(question + suffix)).trim().toLowerCase();
  if (!answer) return defaultYes;
  return answer === "y" || answer === "yes";
}

// ────────────────────────────────────────────────────────────────────
// .env.local read / write
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
 * Update specific keys in an env file's text content while preserving
 * comments, ordering, and unrelated keys. Keys that don't exist yet are
 * appended at the end.
 */
function updateEnvFileContent(
  content: string,
  updates: Record<string, string>,
): string {
  const lines = content.split("\n");
  const updated = new Set<string>();
  const out = lines.map((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) return line;
    const eq = trimmed.indexOf("=");
    if (eq < 0) return line;
    const key = trimmed.slice(0, eq).trim();
    if (key in updates) {
      updated.add(key);
      return `${key}=${updates[key]}`;
    }
    return line;
  });
  const newKeys = Object.keys(updates).filter((k) => !updated.has(k));
  if (newKeys.length > 0) {
    if (out[out.length - 1] !== "") out.push("");
    for (const key of newKeys) out.push(`${key}=${updates[key]}`);
  }
  return out.join("\n");
}

async function loadEnvLocal(): Promise<Record<string, string>> {
  if (!existsSync(ENV_LOCAL_PATH)) {
    if (existsSync(ENV_EXAMPLE_PATH)) {
      fail(
        `web/.env.local not found.\n\n` +
          `Copy web/.env.example to web/.env.local and fill in CLOUDFLARE_API_TOKEN\n` +
          `and CLOUDFLARE_ACCOUNT_ID before running this script. The .env.example\n` +
          `file has step-by-step instructions for getting both values from the\n` +
          `Cloudflare dashboard.\n\n` +
          `Quick copy:\n` +
          `   cp web/.env.example web/.env.local`,
      );
    }
    fail(`web/.env.local not found and web/.env.example is also missing.`);
  }
  const content = await readFile(ENV_LOCAL_PATH, "utf-8");
  return parseEnvFile(content);
}

async function writeEnvLocal(updates: Record<string, string>): Promise<void> {
  const content = await readFile(ENV_LOCAL_PATH, "utf-8");
  const updated = updateEnvFileContent(content, updates);
  await writeFile(ENV_LOCAL_PATH, updated, "utf-8");
}

// ────────────────────────────────────────────────────────────────────
// State file
// ────────────────────────────────────────────────────────────────────

async function loadState(accountId: string): Promise<State> {
  if (!existsSync(STATE_PATH)) {
    return { version: 1, cloudflare: { accountId } };
  }
  const content = await readFile(STATE_PATH, "utf-8");
  let parsed: State;
  try {
    parsed = JSON.parse(content) as State;
  } catch (err) {
    fail(
      `scripts/.r2-state.json is not valid JSON: ${(err as Error).message}\n\n` +
        `Either fix the file by hand or delete it to start fresh.`,
    );
  }
  if (parsed.cloudflare.accountId !== accountId) {
    fail(
      `State file accountId (${parsed.cloudflare.accountId}) does not match\n` +
        `CLOUDFLARE_ACCOUNT_ID in web/.env.local (${accountId}).\n\n` +
        `If you've intentionally switched Cloudflare accounts, delete\n` +
        `scripts/.r2-state.json and re-run this script.`,
    );
  }
  return parsed;
}

async function saveState(state: State): Promise<void> {
  await writeFile(STATE_PATH, JSON.stringify(state, null, 2) + "\n", "utf-8");
}

// ────────────────────────────────────────────────────────────────────
// Cloudflare API client
// ────────────────────────────────────────────────────────────────────

class CloudflareError extends Error {
  constructor(
    public readonly status: number,
    public readonly cfErrors: Array<{ code: number; message: string }>,
    public readonly endpoint: string,
  ) {
    const cfMsg = cfErrors.map((e) => `[${e.code}] ${e.message}`).join("; ");
    super(
      `Cloudflare API ${status} on ${endpoint}: ${cfMsg || "(no error message)"}`,
    );
    this.name = "CloudflareError";
  }
}

async function cfRequest<T>(
  token: string,
  method: string,
  path: string,
  body?: unknown,
): Promise<T> {
  const url = `${CF_API_BASE}${path}`;
  const headers: Record<string, string> = {
    Authorization: `Bearer ${token}`,
  };
  if (body !== undefined) headers["Content-Type"] = "application/json";

  const response = await fetch(url, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  let data: CloudflareEnvelope<T>;
  try {
    data = (await response.json()) as CloudflareEnvelope<T>;
  } catch {
    throw new CloudflareError(response.status, [], `${method} ${path}`);
  }

  if (!response.ok || !data.success) {
    throw new CloudflareError(
      response.status,
      data.errors ?? [],
      `${method} ${path}`,
    );
  }
  return data.result;
}

// ────────────────────────────────────────────────────────────────────
// Cloudflare API operations
// ────────────────────────────────────────────────────────────────────

async function verifyToken(token: string, accountId: string): Promise<void> {
  // Account-scoped verify endpoint. Cloudflare has both /user/tokens/verify
  // (for user-namespace tokens) and /accounts/{id}/tokens/verify (for
  // account-namespace tokens). Tokens created via the dashboard's Account
  // API Tokens flow live in the account namespace and will return 401
  // against the user endpoint.
  const result = await cfRequest<{ id: string; status: string }>(
    token,
    "GET",
    `/accounts/${accountId}/tokens/verify`,
  );
  if (result.status !== "active") {
    fail(`Cloudflare API token is not active (status: ${result.status}).`);
  }
}

async function listMatchingBuckets(
  token: string,
  accountId: string,
): Promise<BucketInfo[]> {
  const path =
    `/accounts/${accountId}/r2/buckets?name_contains=` +
    encodeURIComponent(BUCKET_NAME);
  const result = await cfRequest<{ buckets?: BucketInfo[] }>(
    token,
    "GET",
    path,
  );
  return result.buckets ?? [];
}

async function createBucket(
  token: string,
  accountId: string,
): Promise<BucketInfo> {
  return cfRequest<BucketInfo>(
    token,
    "POST",
    `/accounts/${accountId}/r2/buckets`,
    { name: BUCKET_NAME },
  );
}

async function applyCors(token: string, accountId: string): Promise<void> {
  await cfRequest<unknown>(
    token,
    "PUT",
    `/accounts/${accountId}/r2/buckets/${BUCKET_NAME}/cors`,
    CORS_RULES,
  );
}

async function enableManagedDomain(
  token: string,
  accountId: string,
): Promise<ManagedDomainResult> {
  return cfRequest<ManagedDomainResult>(
    token,
    "PUT",
    `/accounts/${accountId}/r2/buckets/${BUCKET_NAME}/domains/managed`,
    { enabled: true },
  );
}

async function getManagedDomain(
  token: string,
  accountId: string,
): Promise<ManagedDomainResult | null> {
  try {
    return await cfRequest<ManagedDomainResult>(
      token,
      "GET",
      `/accounts/${accountId}/r2/buckets/${BUCKET_NAME}/domains/managed`,
    );
  } catch (err) {
    if (err instanceof CloudflareError && err.status === 404) return null;
    throw err;
  }
}

async function lookupPermissionGroupIds(
  token: string,
  accountId: string,
  names: readonly string[],
): Promise<Record<string, string>> {
  const all: PermissionGroup[] = [];
  let page = 1;
  while (true) {
    const result = await cfRequest<PermissionGroup[]>(
      token,
      "GET",
      `/accounts/${accountId}/tokens/permission_groups?per_page=100&page=${page}`,
    );
    all.push(...result);
    if (result.length < 100) break;
    page++;
    if (page > 50) break; // sanity bound — Cloudflare's permission group list is small
  }

  const byName: Record<string, string> = {};
  for (const target of names) {
    const found = all.find((g) => g.name === target);
    if (!found) {
      fail(
        `Could not find Cloudflare permission group "${target}".\n\n` +
          `The API returned ${all.length} groups total. Cloudflare may have\n` +
          `renamed it. Inspect the full list:\n\n` +
          `   curl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \\\n` +
          `        ${CF_API_BASE}/user/tokens/permission_groups`,
      );
    }
    byName[target] = found.id;
  }
  return byName;
}

async function createR2Token(
  token: string,
  accountId: string,
  permissionGroupIds: Record<string, string>,
): Promise<CreatedToken> {
  const resourceKey =
    `com.cloudflare.edge.r2.bucket.${accountId}_default_${BUCKET_NAME}`;
  return cfRequest<CreatedToken>(
    token,
    "POST",
    `/accounts/${accountId}/tokens`,
    {
      name: RUNTIME_TOKEN_NAME,
      policies: [
        {
          effect: "allow",
          permission_groups: Object.entries(permissionGroupIds).map(
            ([name, id]) => ({ id, name }),
          ),
          resources: { [resourceKey]: "*" },
        },
      ],
    },
  );
}

async function deleteToken(
  token: string,
  accountId: string,
  tokenId: string,
): Promise<void> {
  await cfRequest<unknown>(
    token,
    "DELETE",
    `/accounts/${accountId}/tokens/${tokenId}`,
  );
}

// ────────────────────────────────────────────────────────────────────
// Crypto helpers
// ────────────────────────────────────────────────────────────────────

function deriveS3Secret(tokenValue: string): string {
  return createHash("sha256").update(tokenValue).digest("hex");
}

function hashCorsRules(): string {
  return createHash("sha256").update(JSON.stringify(CORS_RULES)).digest("hex");
}

// ────────────────────────────────────────────────────────────────────
// Permission-error helper — gives consistent guidance for 403s
// ────────────────────────────────────────────────────────────────────

function explainPermissionError(
  err: unknown,
  operation: string,
  scopeHint: string,
): never {
  if (err instanceof CloudflareError && err.status === 403) {
    fail(
      `Cloudflare API token lacks permission for: ${operation}.\n\n` +
        `Underlying error: ${err.message}\n\n` +
        `Add the "${scopeHint}" permission to your token at:\n` +
        `   https://dash.cloudflare.com/profile/api-tokens\n\n` +
        `Then re-run this script. Already-completed steps will be skipped.`,
    );
  }
  throw err;
}

// ────────────────────────────────────────────────────────────────────
// Main flow
// ────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  log("koom R2 Setup");
  log("─────────────");
  log();

  // 1. Load env, sanity check required values.
  log("Reading web/.env.local…");
  const env = await loadEnvLocal();
  const token = env.CLOUDFLARE_API_TOKEN;
  const accountId = env.CLOUDFLARE_ACCOUNT_ID;
  if (!token || !accountId) {
    fail(
      `web/.env.local is missing CLOUDFLARE_API_TOKEN and/or\n` +
        `CLOUDFLARE_ACCOUNT_ID.\n\n` +
        `See web/.env.example for instructions on creating an API token and\n` +
        `finding your account ID in the Cloudflare dashboard.`,
    );
  }
  logSuccess("Found CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID");

  // 2. Validate token is real and active.
  log();
  log("Validating Cloudflare API token…");
  try {
    await verifyToken(token, accountId);
  } catch (err) {
    if (err instanceof CloudflareError) {
      fail(
        `Token validation failed (${err.status}).\n\n` +
          `Underlying error: ${err.message}\n\n` +
          `Re-check the token value in web/.env.local. If you copied it from the\n` +
          `Cloudflare dashboard, make sure you grabbed the full string and that\n` +
          `the token hasn't been deleted or expired.`,
      );
    }
    throw err;
  }
  logSuccess("Token is active");

  // 3. Load state — must agree with the env's account ID.
  const state = await loadState(accountId);

  // 4. Bucket: detect existing or create.
  log();
  log(`Checking for bucket "${BUCKET_NAME}"…`);
  let buckets: BucketInfo[];
  try {
    buckets = await listMatchingBuckets(token, accountId);
  } catch (err) {
    explainPermissionError(
      err,
      "list R2 buckets",
      "Workers R2 Storage: Edit",
    );
  }
  const existingBucket = buckets.find((b) => b.name === BUCKET_NAME);

  if (existingBucket) {
    if (state.cloudflare.bucket?.name === BUCKET_NAME) {
      logSuccess(`Bucket "${BUCKET_NAME}" exists (recognized from prior run)`);
    } else {
      logSuccess(`Bucket "${BUCKET_NAME}" exists`);
      log();
      log(`  This bucket is in your Cloudflare account but is not tracked by`);
      log(`  koom (no entry in scripts/.r2-state.json). It may be from a`);
      log(`  prior koom install or unrelated to koom entirely.`);
      log();
      const reuse = await confirm(
        `  Reuse existing bucket "${BUCKET_NAME}"?`,
        false,
      );
      if (!reuse) {
        fail(
          `Refusing to claim a pre-existing bucket without consent.\n\n` +
            `Either delete the existing bucket from the Cloudflare dashboard\n` +
            `and re-run this script, or rename the existing bucket if you\n` +
            `want to keep it separate from koom.`,
        );
      }
      state.cloudflare.bucket = {
        name: BUCKET_NAME,
        createdByKoom: false,
        createdAt: new Date().toISOString(),
      };
      await saveState(state);
      logSuccess("Recorded as pre-existing (will not be modified on teardown)");
    }
  } else {
    log(`  Bucket does not exist. Creating…`);
    try {
      await createBucket(token, accountId);
    } catch (err) {
      explainPermissionError(
        err,
        "create R2 bucket",
        "Workers R2 Storage: Edit",
      );
    }
    state.cloudflare.bucket = {
      name: BUCKET_NAME,
      createdByKoom: true,
      createdAt: new Date().toISOString(),
    };
    await saveState(state);
    logSuccess(`Bucket "${BUCKET_NAME}" created`);
  }

  // 5. CORS — apply if state hash differs.
  log();
  log("Applying CORS policy…");
  const expectedCorsHash = hashCorsRules();
  if (
    state.cloudflare.cors?.appliedByKoom &&
    state.cloudflare.cors.rulesHash === expectedCorsHash
  ) {
    logSuccess("CORS already up to date (per state file)");
  } else {
    try {
      await applyCors(token, accountId);
    } catch (err) {
      explainPermissionError(
        err,
        "apply CORS policy",
        "Workers R2 Storage: Edit",
      );
    }
    state.cloudflare.cors = {
      appliedByKoom: true,
      rulesHash: expectedCorsHash,
      appliedAt: new Date().toISOString(),
    };
    await saveState(state);
    logSuccess("CORS rules applied (PUT/HEAD/GET from any origin)");
  }

  // 6. Managed public URL — enable and capture the .r2.dev domain.
  log();
  log("Enabling managed public URL…");
  let publicDomain: string;
  if (state.cloudflare.publicAccess?.enabledByKoom) {
    const current = await getManagedDomain(token, accountId).catch((err) => {
      if (err instanceof CloudflareError && err.status === 403) {
        explainPermissionError(
          err,
          "read managed domain status",
          "Workers R2 Storage: Edit",
        );
      }
      throw err;
    });
    if (current?.enabled && current.domain) {
      publicDomain = current.domain;
      logSuccess(`Already enabled: https://${publicDomain}`);
    } else {
      const result = await enableManagedDomain(token, accountId);
      publicDomain = result.domain;
      state.cloudflare.publicAccess = {
        enabledByKoom: true,
        publicBaseUrl: `https://${publicDomain}`,
        enabledAt: new Date().toISOString(),
      };
      await saveState(state);
      logSuccess(`Re-enabled: https://${publicDomain}`);
    }
  } else {
    let result: ManagedDomainResult;
    try {
      result = await enableManagedDomain(token, accountId);
    } catch (err) {
      explainPermissionError(
        err,
        "enable managed public URL",
        "Workers R2 Storage: Edit",
      );
    }
    publicDomain = result.domain;
    state.cloudflare.publicAccess = {
      enabledByKoom: true,
      publicBaseUrl: `https://${publicDomain}`,
      enabledAt: new Date().toISOString(),
    };
    await saveState(state);
    logSuccess(`Enabled: https://${publicDomain}`);
  }

  // 7. R2 S3 token — only mint if env doesn't already have credentials.
  let accessKeyId = env.R2_ACCESS_KEY_ID ?? "";
  let secretAccessKey = env.R2_SECRET_ACCESS_KEY ?? "";
  log();
  if (accessKeyId && secretAccessKey) {
    log("R2 S3 credentials already present in web/.env.local — keeping them.");
    logSuccess(`Access key ID: ${accessKeyId.slice(0, 8)}…`);
  } else {
    log("Creating R2 S3-compatible API token…");

    // 7a. Look up permission group IDs.
    log("  Looking up permission group IDs…");
    let permissionGroupIds: Record<string, string>;
    try {
      permissionGroupIds = await lookupPermissionGroupIds(
        token,
        accountId,
        REQUIRED_PERMISSION_GROUPS,
      );
    } catch (err) {
      if (err instanceof CloudflareError && err.status === 403) {
        fail(
          `Token does not have permission to list permission groups (403).\n\n` +
            `This is unusual — listing permission groups should be available\n` +
            `to any active token. The token may have been disabled or scoped\n` +
            `unusually narrowly.`,
        );
      }
      throw err;
    }
    logSuccess(
      `Found permission groups (${Object.keys(permissionGroupIds).length}/${REQUIRED_PERMISSION_GROUPS.length})`,
    );

    // 7b. If state has a previous token, attempt to delete it before
    //     minting a new one. This prevents orphan accumulation when the
    //     user wipes web/.env.local but keeps the state file.
    if (state.cloudflare.s3Token?.id) {
      log("  State has a previous token; attempting to delete it first…");
      try {
        await deleteToken(token, accountId, state.cloudflare.s3Token.id);
        logSuccess("Old token deleted");
      } catch (err) {
        if (err instanceof CloudflareError && err.status === 404) {
          logSuccess("Old token already gone");
        } else if (err instanceof CloudflareError) {
          logWarn(
            `Could not delete old token (${err.message}); continuing — clean up manually if needed`,
          );
        } else {
          throw err;
        }
      }
    }

    // 7c. Create the new token.
    log("  Minting token scoped to bucket…");
    let created: CreatedToken;
    try {
      created = await createR2Token(token, accountId, permissionGroupIds);
    } catch (err) {
      if (err instanceof CloudflareError && err.status === 403) {
        fail(
          `Cloudflare API token lacks permission to create API tokens (403).\n\n` +
            `Underlying error: ${err.message}\n\n` +
            `Creating R2 S3 credentials requires the "User API Tokens: Edit"\n` +
            `permission, which is in addition to "Workers R2 Storage: Edit".\n` +
            `Update the token at:\n` +
            `   https://dash.cloudflare.com/profile/api-tokens\n\n` +
            `Add a second permission row:\n` +
            `   User → API Tokens → Edit\n\n` +
            `Then re-run. Bucket / CORS / managed URL will be detected as\n` +
            `already-done and only this step will run.`,
        );
      }
      throw err;
    }

    accessKeyId = created.id;
    secretAccessKey = deriveS3Secret(created.value);
    logSuccess(`Token "${created.name}" created`);
    logSuccess(`Access key ID: ${accessKeyId.slice(0, 8)}…`);

    // 7d. Persist the token id to state. Even if the env file write
    //     below fails, we'll know we created this token and can clean
    //     it up on a future run.
    state.cloudflare.s3Token = {
      id: created.id,
      createdByKoom: true,
      createdAt: new Date().toISOString(),
    };
    await saveState(state);
  }

  // 8. Write env vars (idempotent).
  log();
  log("Writing R2_* values to web/.env.local…");
  await writeEnvLocal({
    R2_BUCKET: BUCKET_NAME,
    R2_ACCOUNT_ID: accountId,
    R2_ACCESS_KEY_ID: accessKeyId,
    R2_SECRET_ACCESS_KEY: secretAccessKey,
    R2_PUBLIC_BASE_URL: `https://${publicDomain}`,
  });
  logSuccess("web/.env.local updated");

  // 9. Summary.
  log();
  log("─────────────────────────────────────────────────────");
  log("R2 setup complete.");
  log();
  log(`  Bucket:           ${BUCKET_NAME}`);
  log(`  Public base URL:  https://${publicDomain}`);
  log(`  Access key ID:    ${accessKeyId.slice(0, 8)}…`);
  log(`  State file:       scripts/.r2-state.json`);
  log();
  log(`Re-running this script is safe; it will detect existing state and`);
  log(`only apply changes that are missing.`);
  log();
  log(`Next: a doctor script will land in the next round to verify the`);
  log(`bucket end-to-end (test PUT, public GET, Range request support).`);
}

main().catch((err) => {
  if (err instanceof CloudflareError) {
    process.stderr.write(`\n${err.message}\n`);
    process.exit(1);
  }
  process.stderr.write(
    `\nUnexpected error: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}\n`,
  );
  process.exit(1);
});
