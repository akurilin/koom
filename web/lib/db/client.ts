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

  pool = new pg.Pool({ connectionString });
  return pool;
}
