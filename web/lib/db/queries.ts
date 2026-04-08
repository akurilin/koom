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
