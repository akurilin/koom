#!/usr/bin/env tsx
/*
 * scripts/db.ts
 *
 * koom's database migration tool. One small runner replaces the
 * Supabase CLI: it applies the plain SQL files in `db/migrations/` in
 * filename order and records each applied file in a
 * `schema_migrations` table. The same command runs against the local
 * Docker Postgres during development and against Render Postgres as
 * the web service's pre-deploy step.
 *
 * Subcommands:
 *
 *   migrate       Apply every migration not yet recorded in
 *                 schema_migrations. Each file runs in its own
 *                 transaction together with its bookkeeping row, so
 *                 a failing file leaves no partial state behind.
 *
 *   reset         Drop and recreate the public schema, then migrate.
 *                 Refuses to run against anything but localhost so
 *                 it can never wipe a hosted database.
 *
 *   new <slug>    Scaffold `db/migrations/<UTC timestamp>_<slug>.sql`
 *                 with the header comment block every migration is
 *                 expected to carry.
 *
 * Connection: DATABASE_URL from the environment (Render injects the
 * database's internal connection string), falling back to the local
 * Docker Postgres from docker-compose.yml. SSL behavior comes from the
 * connection string itself (`?sslmode=...`), so no flags are needed.
 */

import { readdir, readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);
const MIGRATIONS_DIR = join(REPO_ROOT, "db", "migrations");

const LOCAL_DATABASE_URL = "postgresql://koom:koom@127.0.0.1:54322/koom";

const USAGE = `Usage:
  npm run db:migrate              # apply pending migrations
  npm run db:reset                # local only: wipe public schema, then migrate
  npm run db:migration:new <slug> # scaffold a new migration file`;

function databaseUrl(): string {
  return process.env.DATABASE_URL || LOCAL_DATABASE_URL;
}

function isLocalDatabase(url: string): boolean {
  const host = new URL(url).hostname;
  return host === "localhost" || host === "127.0.0.1" || host === "::1";
}

/** Redact the password so connection strings are safe to print. */
function describe(url: string): string {
  const u = new URL(url);
  return `${u.hostname}:${u.port || "5432"}${u.pathname}`;
}

async function listMigrationFiles(): Promise<string[]> {
  const entries = await readdir(MIGRATIONS_DIR);
  return entries.filter((name) => name.endsWith(".sql")).sort();
}

async function migrate(client: pg.Client): Promise<void> {
  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
        version    TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);

  const { rows } = await client.query<{ version: string }>(
    "SELECT version FROM schema_migrations",
  );
  const applied = new Set(rows.map((r) => r.version));

  const pending = (await listMigrationFiles()).filter(
    (file) => !applied.has(file.replace(/\.sql$/, "")),
  );

  if (pending.length === 0) {
    console.log("No pending migrations.");
    return;
  }

  for (const file of pending) {
    const version = file.replace(/\.sql$/, "");
    const sql = await readFile(join(MIGRATIONS_DIR, file), "utf-8");
    console.log(`Applying ${file}`);
    try {
      await client.query("BEGIN");
      await client.query(sql);
      await client.query(
        "INSERT INTO schema_migrations (version) VALUES ($1)",
        [version],
      );
      await client.query("COMMIT");
    } catch (err) {
      await client.query("ROLLBACK");
      throw new Error(
        `Migration ${file} failed and was rolled back: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }
  }

  console.log(`Applied ${pending.length} migration(s).`);
}

async function reset(client: pg.Client, url: string): Promise<void> {
  if (!isLocalDatabase(url)) {
    throw new Error(
      `Refusing to reset ${describe(url)}: db:reset only runs against a local database.`,
    );
  }
  console.log(`Resetting public schema on ${describe(url)}`);
  await client.query("DROP SCHEMA public CASCADE");
  await client.query("CREATE SCHEMA public");
  await migrate(client);
}

async function scaffold(slug: string | undefined): Promise<void> {
  if (!slug || !/^[a-z0-9_]+$/.test(slug)) {
    throw new Error(
      `Provide a lowercase snake_case slug, e.g. 'npm run db:migration:new add_recording_views'.`,
    );
  }
  const timestamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const name = `${timestamp}_${slug}.sql`;
  const path = join(MIGRATIONS_DIR, name);
  if (existsSync(path)) throw new Error(`${path} already exists`);
  await writeFile(
    path,
    `-- ${name}\n--\n-- TODO: describe the intent of this migration and any non-obvious\n-- decisions.\n\n`,
  );
  console.log(`Created db/migrations/${name}`);
}

async function withClient(
  url: string,
  fn: (client: pg.Client) => Promise<void>,
): Promise<void> {
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  try {
    await fn(client);
  } finally {
    await client.end();
  }
}

async function main(): Promise<void> {
  const [command, arg] = process.argv.slice(2);
  const url = databaseUrl();

  switch (command) {
    case "migrate":
      console.log(`Migrating ${describe(url)}`);
      await withClient(url, migrate);
      return;
    case "reset":
      await withClient(url, (client) => reset(client, url));
      return;
    case "new":
      await scaffold(arg);
      return;
    default:
      console.error(USAGE);
      process.exit(2);
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
