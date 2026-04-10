/**
 * Query helpers for the koom web app.
 *
 * Parameterized SQL queries against the recordings table, wrapping
 * pg's low-level query interface in small typed functions. No ORM.
 * Keep queries co-located with their result types so route handlers
 * and server components have one import path for database reads.
 */

import { getDb } from "./client";

export interface Recording {
  id: string;
  createdAt: Date;
  title: string | null;
  originalFilename: string;
  durationSeconds: number | null;
  sizeBytes: number;
  contentType: string;
  bucket: string;
  objectKey: string;
}

interface RecordingRow {
  id: string;
  created_at: Date;
  title: string | null;
  original_filename: string;
  duration_seconds: number | null;
  // BIGINT comes back from pg as a string by default to preserve
  // precision. Sizes fit comfortably in JS Number (safe integer max
  // is ~9 PB); converting at the boundary keeps downstream code
  // working with ordinary numbers.
  size_bytes: string;
  content_type: string;
  bucket: string;
  object_key: string;
}

function hydrate(row: RecordingRow): Recording {
  return {
    id: row.id,
    createdAt: row.created_at,
    title: row.title,
    originalFilename: row.original_filename,
    durationSeconds: row.duration_seconds,
    sizeBytes: Number(row.size_bytes),
    contentType: row.content_type,
    bucket: row.bucket,
    objectKey: row.object_key,
  };
}

/**
 * Fetch a single recording by id, filtered to `status = 'complete'`.
 *
 * Pending recordings are intentionally hidden: this function is
 * called from public and admin read paths, and leaking mid-upload
 * rows (with empty or partial R2 objects) would surface broken
 * videos to viewers.
 */
export async function getCompletedRecordingById(
  id: string,
): Promise<Recording | null> {
  const { rows } = await getDb().query<RecordingRow>(
    `SELECT id, created_at, title, original_filename,
            duration_seconds, size_bytes, content_type,
            bucket, object_key
       FROM recordings
      WHERE id = $1 AND status = 'complete'
      LIMIT 1`,
    [id],
  );
  const row = rows[0];
  if (!row) return null;
  return hydrate(row);
}

/**
 * List every complete recording, newest-first. Used by the admin
 * `/app/recordings` page and its backing API route. Excludes
 * pending rows for the same reason `getCompletedRecordingById`
 * does: pending rows don't have a valid R2 object yet, so they
 * can't be played or shared.
 *
 * The listing query is covered by the
 * recordings_status_created_at_idx index created in the initial
 * migration, so it's cheap even with thousands of rows.
 *
 * No server-side pagination — at single-user scale the full list
 * is small and client-side sorting is simpler. If koom ever
 * grows past a few hundred recordings we'd add LIMIT / OFFSET or
 * a keyset cursor here.
 */
export async function listAllCompletedRecordings(): Promise<Recording[]> {
  const { rows } = await getDb().query<RecordingRow>(
    `SELECT id, created_at, title, original_filename,
            duration_seconds, size_bytes, content_type,
            bucket, object_key
       FROM recordings
      WHERE status = 'complete'
      ORDER BY created_at DESC`,
  );
  return rows.map(hydrate);
}

/**
 * Delete a recording row by id. Returns true if a row was
 * removed, false if no matching row existed (so the caller can
 * return 404). Does not touch R2 — the caller is responsible for
 * removing the stored object first.
 */
export async function deleteRecordingById(id: string): Promise<boolean> {
  const result = await getDb().query(`DELETE FROM recordings WHERE id = $1`, [
    id,
  ]);
  return (result.rowCount ?? 0) > 0;
}

/**
 * Overwrite the `title` column of a recording row. Returns true if
 * a row was updated, false if no matching row existed (so the
 * caller can return 404).
 *
 * Pass `null` to clear an existing title. Status is deliberately
 * ignored — both pending and complete rows are updatable so that
 * the desktop client's auto-titler can land a title the moment
 * Whisper + Ollama finish, even if the upload itself is still in
 * flight.
 */
export async function updateRecordingTitle(
  id: string,
  title: string | null,
): Promise<boolean> {
  const result = await getDb().query(
    `UPDATE recordings SET title = $2 WHERE id = $1`,
    [id, title],
  );
  return (result.rowCount ?? 0) > 0;
}

/**
 * Check whether a recording row exists, ignoring its status.
 * Used by the admin delete endpoint to return a clean 404 for
 * unknown ids before attempting the R2 delete.
 */
export async function recordingExists(id: string): Promise<boolean> {
  const { rows } = await getDb().query<{ exists: boolean }>(
    `SELECT 1 AS exists FROM recordings WHERE id = $1 LIMIT 1`,
    [id],
  );
  return rows.length > 0;
}

/**
 * Insert a new recording row with `status = 'pending'`. Called by
 * the upload init endpoint before minting a presigned PUT URL.
 */
export async function insertPendingRecording(opts: {
  id: string;
  title: string | null;
  originalFilename: string;
  durationSeconds: number | null;
  sizeBytes: number;
  contentType: string;
  bucket: string;
  objectKey: string;
}): Promise<void> {
  await getDb().query(
    `INSERT INTO recordings
       (id, status, title, original_filename, duration_seconds,
        size_bytes, content_type, bucket, object_key)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
    [
      opts.id,
      "pending",
      opts.title,
      opts.originalFilename,
      opts.durationSeconds,
      opts.sizeBytes,
      opts.contentType,
      opts.bucket,
      opts.objectKey,
    ],
  );
}

/**
 * Look up a recording's size and status for upload completion
 * verification. Returns null if the row does not exist.
 */
export async function getRecordingForCompletion(
  id: string,
): Promise<{ sizeBytes: number; status: string } | null> {
  const { rows } = await getDb().query<{
    size_bytes: string;
    status: string;
  }>(`SELECT size_bytes, status FROM recordings WHERE id = $1`, [id]);
  const row = rows[0];
  if (!row) return null;
  return { sizeBytes: Number(row.size_bytes), status: row.status };
}

/**
 * Flip a recording's status to `'complete'`. Idempotent — safe to
 * call on a row that is already complete.
 */
export async function completeRecording(id: string): Promise<void> {
  await getDb().query(
    `UPDATE recordings SET status = 'complete' WHERE id = $1`,
    [id],
  );
}

/**
 * Given a list of filenames, return the subset that have at least
 * one completed recording in the database. Used by the desktop
 * client's catch-up diff feature.
 */
export async function getUploadedFilenames(
  filenames: string[],
): Promise<Set<string>> {
  const { rows } = await getDb().query<{ original_filename: string }>(
    `SELECT DISTINCT original_filename
       FROM recordings
      WHERE original_filename = ANY($1)
        AND status = 'complete'`,
    [filenames],
  );
  return new Set(rows.map((r) => r.original_filename));
}
