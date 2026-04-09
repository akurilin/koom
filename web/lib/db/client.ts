/**
 * Postgres connection pool for the koom web app.
 *
 * Lazily initializes a singleton pg.Pool the first time getDb() is
 * called, using DATABASE_URL from the environment. Route handlers
 * import getDb() and call its .query method with parameterized
 * statements — there is no ORM layer.
 *
 * Lazy init matters because process.env may not be populated at
 * module import time in some test setups; deferring Pool
 * construction to first use keeps the module safely importable in
 * any context.
 */

import type { Pool } from "pg";
import pg from "pg";

let pool: Pool | null = null;

export function getDb(): Pool {
  if (pool) return pool;

  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error(
      "DATABASE_URL is not set. The web app cannot reach Postgres.",
    );
  }

  // Local Supabase (via `supabase start`) runs over plaintext on
  // localhost:54322 and doesn't negotiate TLS. Managed providers —
  // including Supabase Cloud's pooler at pooler.supabase.com:6543 —
  // require TLS and reject unencrypted connections, and node-postgres
  // won't enable SSL just because the server asks for it: we have to
  // set it explicitly here. Detect by hostname so the same code
  // handles dev and prod without an extra env var.
  const isLocal =
    connectionString.includes("localhost") ||
    connectionString.includes("127.0.0.1");

  pool = new pg.Pool({
    connectionString,
    ssl: isLocal ? undefined : { rejectUnauthorized: false },
  });
  return pool;
}
