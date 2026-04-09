#!/usr/bin/env tsx
/*
 * scripts/r2-orphans.ts
 *
 * Audit Cloudflare R2 objects under the recordings prefix and flag
 * any object whose recording id does not exist in the configured
 * Postgres databases.
 *
 * Default behavior:
 *   - Read R2 credentials and the local DATABASE_URL from web/.env.local
 *   - Scan the shared R2 bucket under `recordings/`
 *   - Compare each `recordings/{id}/...` object against the union of
 *     ids from every configured database source
 *   - Print a dry-run report only
 *
 * Optional behavior:
 *   - Add a second database source with --prod-db-url or
 *     --prod-env-file
 *   - Delete orphaned objects with the explicit --delete switch
 *
 * Safety rules:
 *   - Only keys that match the expected `recordings/{id}/...` layout
 *     are considered deletion candidates
 *   - Keys under the prefix that do not match that layout are reported
 *     separately and never auto-deleted by this script
 */

import {
  DeleteObjectCommand,
  ListObjectsV2Command,
  S3Client,
} from "@aws-sdk/client-s3";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const { Client: PgClient } = pg;

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);
const DEFAULT_ENV_FILE = join(REPO_ROOT, "web", ".env.local");
const DEFAULT_PREFIX = "recordings/";

const REQUIRED_R2_ENV_VARS = [
  "R2_BUCKET",
  "R2_ACCOUNT_ID",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
] as const;

interface ParsedArgs {
  envFile: string;
  prodDbUrl?: string;
  prodEnvFile?: string;
  prefix: string;
  deleteMode: boolean;
  help: boolean;
}

interface DbSource {
  name: string;
  description: string;
  connectionString: string;
}

interface LoadedDbSource {
  name: string;
  description: string;
  ids: Set<string>;
}

interface ListedObject {
  key: string;
  size: number;
}

interface OrphanGroup {
  recordingId: string;
  objectCount: number;
  totalBytes: number;
  keys: string[];
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }

  const envFile = resolvePathArg(args.envFile);
  const prodEnvFile = args.prodEnvFile
    ? resolvePathArg(args.prodEnvFile)
    : undefined;

  const r2Env = await loadEnvFile(envFile);
  assertRequiredEnvVars(r2Env, REQUIRED_R2_ENV_VARS, envFile);

  const dbSources = await buildDbSources({
    envFile,
    env: r2Env,
    prodDbUrl: args.prodDbUrl,
    prodEnvFile,
  });

  if (dbSources.length === 0) {
    throw new Error(
      "No database sources configured. Provide DATABASE_URL in the main env file or pass --prod-db-url / --prod-env-file.",
    );
  }

  log("koom R2 Orphan Audit");
  log("─────────────────────");
  log("");
  log(`Mode:               ${args.deleteMode ? "delete" : "dry-run"}`);
  log(`R2 env file:        ${friendlyPath(envFile)}`);
  log(`Bucket:             ${r2Env.R2_BUCKET}`);
  log(`Prefix:             ${normalizePrefix(args.prefix)}`);
  log(`Database sources:   ${dbSources.length}`);
  for (const source of dbSources) {
    log(`  - ${source.name}: ${source.description}`);
  }

  const loadedSources = await loadDbSources(dbSources);
  const referencedIds = mergeReferencedIds(loadedSources);
  const r2 = buildR2Client(r2Env);
  const prefix = normalizePrefix(args.prefix);
  const objects = await listObjects(r2, r2Env.R2_BUCKET, prefix);

  const orphanObjects: ListedObject[] = [];
  const unknownLayoutObjects: ListedObject[] = [];
  let referencedObjectCount = 0;
  let referencedBytes = 0;

  for (const object of objects) {
    const recordingId = extractRecordingId(object.key, prefix);
    if (!recordingId) {
      unknownLayoutObjects.push(object);
      continue;
    }

    if (referencedIds.has(recordingId)) {
      referencedObjectCount++;
      referencedBytes += object.size;
      continue;
    }

    orphanObjects.push(object);
  }

  const orphanGroups = groupOrphans(orphanObjects, prefix);
  const orphanBytes = orphanObjects.reduce(
    (sum, object) => sum + object.size,
    0,
  );
  const unknownBytes = unknownLayoutObjects.reduce(
    (sum, object) => sum + object.size,
    0,
  );

  log("");
  log("Scan Summary");
  log(`  R2 objects scanned:      ${objects.length}`);
  log(
    `  Referenced DB ids:       ${referencedIds.size} unique across ${loadedSources.length} source(s)`,
  );
  for (const source of loadedSources) {
    log(`  ${source.name} ids:           ${source.ids.size}`);
  }
  log(
    `  Referenced objects:      ${referencedObjectCount} (${formatBytes(referencedBytes)})`,
  );
  log(
    `  Orphan objects:          ${orphanObjects.length} (${formatBytes(orphanBytes)})`,
  );
  log(`  Orphan recording ids:    ${orphanGroups.length}`);
  log(
    `  Unknown-layout objects:  ${unknownLayoutObjects.length} (${formatBytes(unknownBytes)})`,
  );

  if (orphanGroups.length > 0) {
    log("");
    log("Orphaned Recording Prefixes");
    for (const group of orphanGroups) {
      log(
        `  - ${group.recordingId}: ${group.objectCount} object(s), ${formatBytes(group.totalBytes)}`,
      );
      for (const key of group.keys) {
        log(`      ${key}`);
      }
    }
  }

  if (unknownLayoutObjects.length > 0) {
    log("");
    log("Unknown Layout Objects");
    log(
      "  These keys live under the scanned prefix but do not match the expected recordings/{id}/... layout.",
    );
    log("  They are reported only and will never be deleted by this script.");
    for (const object of unknownLayoutObjects) {
      log(`  - ${object.key} (${formatBytes(object.size)})`);
    }
  }

  if (!args.deleteMode) {
    log("");
    if (orphanObjects.length === 0) {
      log("No orphaned recording objects found.");
    } else {
      log(
        `Dry run only. Re-run with --delete to remove ${orphanObjects.length} orphaned object(s).`,
      );
    }
    return;
  }

  if (orphanObjects.length === 0) {
    log("");
    log("Delete mode requested, but there is nothing to delete.");
    return;
  }

  log("");
  log(`Deleting ${orphanObjects.length} orphaned object(s)...`);
  for (const object of orphanObjects) {
    await r2.send(
      new DeleteObjectCommand({
        Bucket: r2Env.R2_BUCKET,
        Key: object.key,
      }),
    );
    log(`  deleted ${object.key}`);
  }
  log("");
  log(
    `Deleted ${orphanObjects.length} orphaned object(s), reclaiming ${formatBytes(orphanBytes)}.`,
  );
}

function parseArgs(argv: string[]): ParsedArgs {
  const parsed: ParsedArgs = {
    envFile: DEFAULT_ENV_FILE,
    prefix: DEFAULT_PREFIX,
    deleteMode: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (!arg) continue;

    switch (arg) {
      case "--env-file":
        parsed.envFile = requireValue(argv, ++index, "--env-file");
        break;
      case "--prod-db-url":
        parsed.prodDbUrl = requireValue(argv, ++index, "--prod-db-url");
        break;
      case "--prod-env-file":
        parsed.prodEnvFile = requireValue(argv, ++index, "--prod-env-file");
        break;
      case "--prefix":
        parsed.prefix = requireValue(argv, ++index, "--prefix");
        break;
      case "--delete":
        parsed.deleteMode = true;
        break;
      case "--help":
      case "-h":
        parsed.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (parsed.prodDbUrl && parsed.prodEnvFile) {
    throw new Error(
      "Choose either --prod-db-url or --prod-env-file, not both.",
    );
  }

  return parsed;
}

function printHelp(): void {
  log("Usage:");
  log("  npm run r2:orphans -- [options]");
  log("");
  log("Options:");
  log(
    `  --env-file <path>      Env file that supplies R2_* values and the local DATABASE_URL (default: ${friendlyPath(DEFAULT_ENV_FILE)})`,
  );
  log(
    "  --prod-db-url <url>   Optional production DATABASE_URL to union with the local database",
  );
  log(
    "  --prod-env-file <path> Optional env file whose DATABASE_URL should be treated as the production database",
  );
  log(
    `  --prefix <prefix>      Object prefix to scan (default: ${DEFAULT_PREFIX})`,
  );
  log(
    "  --delete               Delete orphaned objects instead of reporting them",
  );
  log("  --help, -h             Show this help text");
  log("");
  log("Examples:");
  log("  npm run r2:orphans");
  log(
    "  npm run r2:orphans -- --prod-db-url 'postgresql://user:pass@host:6543/postgres'",
  );
  log(
    "  npm run r2:orphans -- --prod-env-file web/.env.production.local --delete",
  );
}

async function buildDbSources(opts: {
  envFile: string;
  env: Record<string, string>;
  prodDbUrl?: string;
  prodEnvFile?: string;
}): Promise<DbSource[]> {
  const sources: DbSource[] = [];

  if (opts.env.DATABASE_URL) {
    sources.push({
      name: "local",
      description: friendlyPath(opts.envFile),
      connectionString: opts.env.DATABASE_URL,
    });
  }

  if (opts.prodDbUrl) {
    sources.push({
      name: "production",
      description: "CLI --prod-db-url",
      connectionString: opts.prodDbUrl,
    });
  } else if (opts.prodEnvFile) {
    const prodEnv = await loadEnvFile(opts.prodEnvFile);
    const databaseUrl = prodEnv.DATABASE_URL;
    if (!databaseUrl) {
      throw new Error(
        `DATABASE_URL not found in production env file ${friendlyPath(opts.prodEnvFile)}.`,
      );
    }
    sources.push({
      name: "production",
      description: friendlyPath(opts.prodEnvFile),
      connectionString: databaseUrl,
    });
  }

  return sources;
}

async function loadDbSources(sources: DbSource[]): Promise<LoadedDbSource[]> {
  const loaded: LoadedDbSource[] = [];

  for (const source of sources) {
    log("");
    log(`Loading ${source.name} database ids...`);

    const client = new PgClient({ connectionString: source.connectionString });
    try {
      await client.connect();
      const result = await client.query<{ id: string }>(
        `SELECT id
           FROM recordings`,
      );
      const ids = new Set(result.rows.map((row) => row.id));
      loaded.push({
        name: source.name,
        description: source.description,
        ids,
      });
      log(`  loaded ${ids.size} id(s) from ${source.description}`);
    } finally {
      await client.end().catch(() => undefined);
    }
  }

  return loaded;
}

function mergeReferencedIds(sources: LoadedDbSource[]): Set<string> {
  const merged = new Set<string>();
  for (const source of sources) {
    for (const id of source.ids) {
      merged.add(id);
    }
  }
  return merged;
}

function buildR2Client(env: Record<string, string>): S3Client {
  return new S3Client({
    region: "auto",
    endpoint: `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: env.R2_ACCESS_KEY_ID,
      secretAccessKey: env.R2_SECRET_ACCESS_KEY,
    },
  });
}

async function listObjects(
  r2: S3Client,
  bucket: string,
  prefix: string,
): Promise<ListedObject[]> {
  log("");
  log(`Listing R2 objects under s3://${bucket}/${prefix} ...`);

  const objects: ListedObject[] = [];
  let continuationToken: string | undefined;

  do {
    const result = await r2.send(
      new ListObjectsV2Command({
        Bucket: bucket,
        Prefix: prefix,
        ContinuationToken: continuationToken,
      }),
    );

    for (const item of result.Contents ?? []) {
      if (!item.Key) continue;
      objects.push({
        key: item.Key,
        size: Number(item.Size ?? 0),
      });
    }

    continuationToken = result.IsTruncated
      ? result.NextContinuationToken
      : undefined;
  } while (continuationToken);

  log(`  listed ${objects.length} object(s)`);
  return objects;
}

function groupOrphans(objects: ListedObject[], prefix: string): OrphanGroup[] {
  const groups = new Map<string, OrphanGroup>();

  for (const object of objects) {
    const recordingId = extractRecordingId(object.key, prefix);
    if (!recordingId) continue;

    const existing = groups.get(recordingId);
    if (existing) {
      existing.objectCount++;
      existing.totalBytes += object.size;
      existing.keys.push(object.key);
      continue;
    }

    groups.set(recordingId, {
      recordingId,
      objectCount: 1,
      totalBytes: object.size,
      keys: [object.key],
    });
  }

  return [...groups.values()].sort((a, b) => {
    if (b.totalBytes !== a.totalBytes) return b.totalBytes - a.totalBytes;
    return a.recordingId.localeCompare(b.recordingId);
  });
}

function extractRecordingId(key: string, prefix: string): string | null {
  if (!key.startsWith(prefix)) return null;

  const remainder = key.slice(prefix.length);
  const slashIndex = remainder.indexOf("/");
  if (slashIndex <= 0) return null;

  const recordingId = remainder.slice(0, slashIndex).trim();
  return recordingId || null;
}

function normalizePrefix(prefix: string): string {
  const trimmed = prefix.trim().replace(/^\/+/, "");
  if (!trimmed) {
    throw new Error("Prefix must not be empty.");
  }
  return trimmed.endsWith("/") ? trimmed : `${trimmed}/`;
}

function requireValue(argv: string[], index: number, flag: string): string {
  const value = argv[index];
  if (!value || value.startsWith("--")) {
    throw new Error(`Missing value for ${flag}`);
  }
  return value;
}

async function loadEnvFile(path: string): Promise<Record<string, string>> {
  if (!existsSync(path)) {
    throw new Error(`Env file not found: ${friendlyPath(path)}`);
  }
  return parseEnvFile(await readFile(path, "utf-8"));
}

function parseEnvFile(content: string): Record<string, string> {
  const result: Record<string, string> = {};

  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const equalsIndex = trimmed.indexOf("=");
    if (equalsIndex < 0) continue;

    const key = trimmed.slice(0, equalsIndex).trim();
    let value = trimmed.slice(equalsIndex + 1).trim();
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

function assertRequiredEnvVars(
  env: Record<string, string>,
  keys: readonly string[],
  path: string,
): void {
  const missing = keys.filter((key) => !env[key]);
  if (missing.length === 0) return;

  throw new Error(
    `Missing required env var(s) in ${friendlyPath(path)}: ${missing.join(", ")}`,
  );
}

function resolvePathArg(path: string): string {
  if (isAbsolute(path)) return path;
  return resolve(process.cwd(), path);
}

function friendlyPath(path: string): string {
  if (path.startsWith(REPO_ROOT + "/")) {
    return path.slice(REPO_ROOT.length + 1);
  }
  if (path === REPO_ROOT) return ".";
  return path;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;

  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unitIndex = 0;

  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }

  return `${value.toFixed(value >= 10 ? 1 : 2)} ${units[unitIndex]}`;
}

function log(message = ""): void {
  process.stdout.write(message + "\n");
}

void main().catch((err: unknown) => {
  const message = err instanceof Error ? err.message : String(err);
  process.stderr.write(`Error: ${message}\n`);
  process.exitCode = 1;
});
