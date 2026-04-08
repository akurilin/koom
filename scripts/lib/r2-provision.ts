/*
 * scripts/lib/r2-provision.ts
 *
 * Shared Cloudflare R2 provisioning logic, parameterized so we can run
 * it against either the production bucket or a separate test bucket.
 *
 * Callers: scripts/r2-setup.ts (production) and
 * scripts/r2-setup-test.ts (test). Both scripts are thin wrappers that
 * just pick the right options and hand them to `provisionR2()`.
 *
 * What "provisioning" means here:
 *   1. Read CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID from the
 *      credentials env file (always web/.env.local — that's where the
 *      user's Cloudflare API token lives, whether we're provisioning
 *      prod or test).
 *   2. Verify the token.
 *   3. Detect or create the bucket. Pre-existing buckets are never
 *      reconfigured without explicit user consent, and `createdByKoom`
 *      is tracked in the state file so a future teardown command can
 *      safely remove only resources it created.
 *   4. Apply the standard koom CORS policy.
 *   5. Enable the managed .r2.dev public URL.
 *   6. Mint an R2 S3-compatible API token scoped to this single
 *      bucket, unless credentials are already present in the output
 *      env file.
 *   7. Write R2_BUCKET / R2_ACCOUNT_ID / R2_ACCESS_KEY_ID /
 *      R2_SECRET_ACCESS_KEY / R2_PUBLIC_BASE_URL into the output env
 *      file. Other existing values in that file are preserved.
 *
 * State is tracked in a caller-supplied JSON file so production and
 * test runs don't share state. Credentials live in a caller-supplied
 * env file so they don't either.
 */

import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { stdin as input, stdout as output } from "node:process";
import * as readline from "node:readline/promises";

// ────────────────────────────────────────────────────────────────────
// Public types
// ────────────────────────────────────────────────────────────────────

export interface ProvisionOptions {
  /** Human-readable banner, e.g. "koom R2 Setup". */
  displayName: string;
  /** Bucket name in Cloudflare, e.g. "koom-recordings". */
  bucketName: string;
  /** Token name Cloudflare will display, e.g. "koom-runtime-r2". */
  runtimeTokenName: string;
  /** Absolute path to the JSON state file for this bucket. */
  stateFilePath: string;
  /**
   * Absolute path to the env file we read CLOUDFLARE_API_TOKEN and
   * CLOUDFLARE_ACCOUNT_ID from. Always web/.env.local in practice,
   * but the path is injected to keep this module side-effect-free.
   */
  credentialsEnvPath: string;
  /**
   * Absolute path to the env file we write R2_* values to. This is
   * web/.env.local for production and web/.env.test.local for test.
   * May or may not exist when provisioning starts; the caller
   * guarantees the file is present (caller creates it from a
   * template if needed).
   */
  outputEnvPath: string;
}

// ────────────────────────────────────────────────────────────────────
// Constants
// ────────────────────────────────────────────────────────────────────

const CF_API_BASE = "https://api.cloudflare.com/client/v4";

/**
 * CORS rules sent via the Cloudflare REST API. Field names are
 * camelCase, not the AllowedMethods/AllowedOrigins style used by the
 * S3 XML API. The desktop client never enforces CORS (it's a native
 * HTTP client), but a browser-based admin upload page would, and
 * allowing PUT/HEAD/GET from any origin keeps both paths working
 * without making the script jurisdiction-aware.
 */
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

/**
 * Permission group names looked up at runtime — Cloudflare's UUIDs
 * for these vary by account type, so hardcoding them is not safe.
 * The names are stable.
 */
const REQUIRED_PERMISSION_GROUPS = [
  "Workers R2 Storage Bucket Item Write",
  "Workers R2 Storage Bucket Item Read",
] as const;

// ────────────────────────────────────────────────────────────────────
// State file shape
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

// ────────────────────────────────────────────────────────────────────
// Cloudflare API types
// ────────────────────────────────────────────────────────────────────

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
// Env file read / write
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
 * Update specific keys in an env file's text content while
 * preserving comments, ordering, and unrelated keys. Keys that
 * don't exist yet are appended at the end.
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

async function loadCredentialsEnv(
  path: string,
): Promise<Record<string, string>> {
  if (!existsSync(path)) {
    fail(
      `Credentials env file not found at ${path}.\n\n` +
        `This file needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID set.\n` +
        `For production provisioning, copy web/.env.example to web/.env.local\n` +
        `and follow the Cloudflare setup instructions in that template.`,
    );
  }
  const content = await readFile(path, "utf-8");
  return parseEnvFile(content);
}

async function loadOutputEnv(path: string): Promise<Record<string, string>> {
  // The output env file is expected to exist (the caller is
  // responsible for creating it from a template if needed). Read
  // its current values so we can preserve anything non-R2_*.
  if (!existsSync(path)) {
    fail(
      `Output env file not found at ${path}.\n\n` +
        `This is a bug — the caller should have created this file before\n` +
        `calling provisionR2().`,
    );
  }
  const content = await readFile(path, "utf-8");
  return parseEnvFile(content);
}

async function writeOutputEnv(
  path: string,
  updates: Record<string, string>,
): Promise<void> {
  const content = await readFile(path, "utf-8");
  const updated = updateEnvFileContent(content, updates);
  await writeFile(path, updated, "utf-8");
}

// ────────────────────────────────────────────────────────────────────
// State file
// ────────────────────────────────────────────────────────────────────

async function loadState(
  statePath: string,
  accountId: string,
): Promise<State> {
  if (!existsSync(statePath)) {
    return { version: 1, cloudflare: { accountId } };
  }
  const content = await readFile(statePath, "utf-8");
  let parsed: State;
  try {
    parsed = JSON.parse(content) as State;
  } catch (err) {
    fail(
      `${statePath} is not valid JSON: ${(err as Error).message}\n\n` +
        `Either fix the file by hand or delete it to start fresh.`,
    );
  }
  if (parsed.cloudflare.accountId !== accountId) {
    fail(
      `State file accountId (${parsed.cloudflare.accountId}) does not\n` +
        `match the CLOUDFLARE_ACCOUNT_ID (${accountId}) from the\n` +
        `credentials env file.\n\n` +
        `If you've intentionally switched Cloudflare accounts, delete\n` +
        `${statePath} and re-run this script.`,
    );
  }
  return parsed;
}

async function saveState(statePath: string, state: State): Promise<void> {
  await writeFile(statePath, JSON.stringify(state, null, 2) + "\n", "utf-8");
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
// Cloudflare operations (parameterized by bucket name)
// ────────────────────────────────────────────────────────────────────

async function verifyToken(token: string, accountId: string): Promise<void> {
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
  bucketName: string,
): Promise<BucketInfo[]> {
  const path =
    `/accounts/${accountId}/r2/buckets?name_contains=` +
    encodeURIComponent(bucketName);
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
  bucketName: string,
): Promise<BucketInfo> {
  return cfRequest<BucketInfo>(
    token,
    "POST",
    `/accounts/${accountId}/r2/buckets`,
    { name: bucketName },
  );
}

async function applyCors(
  token: string,
  accountId: string,
  bucketName: string,
): Promise<void> {
  await cfRequest<unknown>(
    token,
    "PUT",
    `/accounts/${accountId}/r2/buckets/${bucketName}/cors`,
    CORS_RULES,
  );
}

async function enableManagedDomain(
  token: string,
  accountId: string,
  bucketName: string,
): Promise<ManagedDomainResult> {
  return cfRequest<ManagedDomainResult>(
    token,
    "PUT",
    `/accounts/${accountId}/r2/buckets/${bucketName}/domains/managed`,
    { enabled: true },
  );
}

async function getManagedDomain(
  token: string,
  accountId: string,
  bucketName: string,
): Promise<ManagedDomainResult | null> {
  try {
    return await cfRequest<ManagedDomainResult>(
      token,
      "GET",
      `/accounts/${accountId}/r2/buckets/${bucketName}/domains/managed`,
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
    if (page > 50) break;
  }

  const byName: Record<string, string> = {};
  for (const target of names) {
    const found = all.find((g) => g.name === target);
    if (!found) {
      fail(
        `Could not find Cloudflare permission group "${target}".\n\n` +
          `The API returned ${all.length} groups total. Cloudflare may have\n` +
          `renamed it.`,
      );
    }
    byName[target] = found.id;
  }
  return byName;
}

async function createR2Token(
  token: string,
  accountId: string,
  bucketName: string,
  runtimeTokenName: string,
  permissionGroupIds: Record<string, string>,
): Promise<CreatedToken> {
  const resourceKey =
    `com.cloudflare.edge.r2.bucket.${accountId}_default_${bucketName}`;
  return cfRequest<CreatedToken>(
    token,
    "POST",
    `/accounts/${accountId}/tokens`,
    {
      name: runtimeTokenName,
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
// Main provisioning flow
// ────────────────────────────────────────────────────────────────────

export async function provisionR2(opts: ProvisionOptions): Promise<void> {
  log(opts.displayName);
  log("─".repeat(opts.displayName.length));
  log();

  // 1. Load credentials
  log(`Reading credentials from ${friendlyPath(opts.credentialsEnvPath)}…`);
  const credsEnv = await loadCredentialsEnv(opts.credentialsEnvPath);
  const token = credsEnv.CLOUDFLARE_API_TOKEN;
  const accountId = credsEnv.CLOUDFLARE_ACCOUNT_ID;
  if (!token || !accountId) {
    fail(
      `${friendlyPath(opts.credentialsEnvPath)} is missing CLOUDFLARE_API_TOKEN\n` +
        `and/or CLOUDFLARE_ACCOUNT_ID.\n\n` +
        `See web/.env.example for instructions on creating an API token and\n` +
        `finding your account ID in the Cloudflare dashboard.`,
    );
  }
  logSuccess("Found CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID");

  // 2. Verify token
  log();
  log("Validating Cloudflare API token…");
  try {
    await verifyToken(token, accountId);
  } catch (err) {
    if (err instanceof CloudflareError) {
      fail(
        `Token validation failed (${err.status}).\n\n` +
          `Underlying error: ${err.message}\n\n` +
          `Re-check the token value in ${friendlyPath(opts.credentialsEnvPath)}.`,
      );
    }
    throw err;
  }
  logSuccess("Token is active");

  // 3. Load state
  const state = await loadState(opts.stateFilePath, accountId);

  // 4. Bucket
  log();
  log(`Checking for bucket "${opts.bucketName}"…`);
  let buckets: BucketInfo[];
  try {
    buckets = await listMatchingBuckets(token, accountId, opts.bucketName);
  } catch (err) {
    explainPermissionError(err, "list R2 buckets", "Workers R2 Storage: Edit");
  }
  const existingBucket = buckets.find((b) => b.name === opts.bucketName);

  if (existingBucket) {
    if (state.cloudflare.bucket?.name === opts.bucketName) {
      logSuccess(
        `Bucket "${opts.bucketName}" exists (recognized from prior run)`,
      );
    } else {
      logSuccess(`Bucket "${opts.bucketName}" exists`);
      log();
      log(`  This bucket is in your Cloudflare account but is not tracked by`);
      log(`  koom (no entry in ${friendlyPath(opts.stateFilePath)}). It may be`);
      log(`  from a prior koom install or unrelated to koom entirely.`);
      log();
      const reuse = await confirm(
        `  Reuse existing bucket "${opts.bucketName}"?`,
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
        name: opts.bucketName,
        createdByKoom: false,
        createdAt: new Date().toISOString(),
      };
      await saveState(opts.stateFilePath, state);
      logSuccess("Recorded as pre-existing (will not be modified on teardown)");
    }
  } else {
    log(`  Bucket does not exist. Creating…`);
    try {
      await createBucket(token, accountId, opts.bucketName);
    } catch (err) {
      explainPermissionError(
        err,
        "create R2 bucket",
        "Workers R2 Storage: Edit",
      );
    }
    state.cloudflare.bucket = {
      name: opts.bucketName,
      createdByKoom: true,
      createdAt: new Date().toISOString(),
    };
    await saveState(opts.stateFilePath, state);
    logSuccess(`Bucket "${opts.bucketName}" created`);
  }

  // 5. CORS
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
      await applyCors(token, accountId, opts.bucketName);
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
    await saveState(opts.stateFilePath, state);
    logSuccess("CORS rules applied (PUT/HEAD/GET from any origin)");
  }

  // 6. Managed public URL
  log();
  log("Enabling managed public URL…");
  let publicDomain: string;
  if (state.cloudflare.publicAccess?.enabledByKoom) {
    const current = await getManagedDomain(
      token,
      accountId,
      opts.bucketName,
    ).catch((err) => {
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
      const result = await enableManagedDomain(
        token,
        accountId,
        opts.bucketName,
      );
      publicDomain = result.domain;
      state.cloudflare.publicAccess = {
        enabledByKoom: true,
        publicBaseUrl: `https://${publicDomain}`,
        enabledAt: new Date().toISOString(),
      };
      await saveState(opts.stateFilePath, state);
      logSuccess(`Re-enabled: https://${publicDomain}`);
    }
  } else {
    let result: ManagedDomainResult;
    try {
      result = await enableManagedDomain(token, accountId, opts.bucketName);
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
    await saveState(opts.stateFilePath, state);
    logSuccess(`Enabled: https://${publicDomain}`);
  }

  // 7. R2 S3 token (only mint if output env file doesn't already
  //    have credentials)
  const outputEnv = await loadOutputEnv(opts.outputEnvPath);
  let accessKeyId = outputEnv.R2_ACCESS_KEY_ID ?? "";
  let secretAccessKey = outputEnv.R2_SECRET_ACCESS_KEY ?? "";
  log();
  if (accessKeyId && secretAccessKey) {
    log(
      `R2 S3 credentials already present in ${friendlyPath(opts.outputEnvPath)} — keeping them.`,
    );
    logSuccess(`Access key ID: ${accessKeyId.slice(0, 8)}…`);
  } else {
    log("Creating R2 S3-compatible API token…");

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
          `Token does not have permission to list permission groups (403).`,
        );
      }
      throw err;
    }
    logSuccess(
      `Found permission groups (${Object.keys(permissionGroupIds).length}/${REQUIRED_PERMISSION_GROUPS.length})`,
    );

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

    log("  Minting token scoped to bucket…");
    let created: CreatedToken;
    try {
      created = await createR2Token(
        token,
        accountId,
        opts.bucketName,
        opts.runtimeTokenName,
        permissionGroupIds,
      );
    } catch (err) {
      if (err instanceof CloudflareError && err.status === 403) {
        fail(
          `Cloudflare API token lacks permission to create API tokens (403).\n\n` +
            `Underlying error: ${err.message}\n\n` +
            `Creating R2 S3 credentials requires the "User API Tokens: Edit"\n` +
            `permission, which is in addition to "Workers R2 Storage: Edit".\n` +
            `Update the token at:\n` +
            `   https://dash.cloudflare.com/profile/api-tokens`,
        );
      }
      throw err;
    }

    accessKeyId = created.id;
    secretAccessKey = deriveS3Secret(created.value);
    logSuccess(`Token "${created.name}" created`);
    logSuccess(`Access key ID: ${accessKeyId.slice(0, 8)}…`);

    state.cloudflare.s3Token = {
      id: created.id,
      createdByKoom: true,
      createdAt: new Date().toISOString(),
    };
    await saveState(opts.stateFilePath, state);
  }

  // 8. Write env vars
  log();
  log(`Writing R2_* values to ${friendlyPath(opts.outputEnvPath)}…`);
  await writeOutputEnv(opts.outputEnvPath, {
    R2_BUCKET: opts.bucketName,
    R2_ACCOUNT_ID: accountId,
    R2_ACCESS_KEY_ID: accessKeyId,
    R2_SECRET_ACCESS_KEY: secretAccessKey,
    R2_PUBLIC_BASE_URL: `https://${publicDomain}`,
  });
  logSuccess(`${friendlyPath(opts.outputEnvPath)} updated`);

  // 9. Summary
  log();
  log("─────────────────────────────────────────────────────");
  log("R2 setup complete.");
  log();
  log(`  Bucket:           ${opts.bucketName}`);
  log(`  Public base URL:  https://${publicDomain}`);
  log(`  Access key ID:    ${accessKeyId.slice(0, 8)}…`);
  log(`  State file:       ${friendlyPath(opts.stateFilePath)}`);
  log(`  Output env file:  ${friendlyPath(opts.outputEnvPath)}`);
  log();
  log(`Re-running this script is safe; it will detect existing state and`);
  log(`only apply changes that are missing.`);
}

/**
 * Shortens an absolute path to a repo-root-relative display form
 * when possible, for friendlier log output.
 */
function friendlyPath(absolutePath: string): string {
  const cwd = process.cwd();
  if (absolutePath.startsWith(cwd + "/")) {
    return absolutePath.slice(cwd.length + 1);
  }
  return absolutePath;
}
