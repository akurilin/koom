/**
 * Query helpers for the comment system.
 *
 * Same patterns as queries.ts: typed row interfaces, a hydrate
 * function, and parameterized SQL queries through the shared
 * pg Pool. No ORM.
 *
 * Display names are computed, not stored:
 *   - Admin comments → "Admin"
 *   - Anonymous comments → "Guest " + first 4 hex chars of commenter id
 */

import { getDb } from "./client";

// ────────────────────────────────────────────────────────────────
// Types
// ────────────────────────────────────────────────────────────────

export interface Comment {
  id: string;
  recordingId: string;
  commenterId: string | null;
  isAdmin: boolean;
  displayName: string;
  body: string;
  timestampSeconds: number;
  createdAt: Date;
}

interface CommentRow {
  id: string;
  recording_id: string;
  commenter_id: string | null;
  is_admin: boolean;
  body: string;
  timestamp_seconds: number;
  created_at: Date;
}

// ────────────────────────────────────────────────────────────────
// Hydration
// ────────────────────────────────────────────────────────────────

function hydrateComment(row: CommentRow): Comment {
  return {
    id: row.id,
    recordingId: row.recording_id,
    commenterId: row.commenter_id,
    isAdmin: row.is_admin,
    displayName: row.is_admin
      ? "Admin"
      : `Guest ${(row.commenter_id ?? "").slice(0, 4)}`,
    body: row.body,
    timestampSeconds: row.timestamp_seconds,
    createdAt: row.created_at,
  };
}

// ────────────────────────────────────────────────────────────────
// Queries
// ────────────────────────────────────────────────────────────────

/**
 * List all comments for a recording, ordered by timeline position
 * then by insertion time. The composite index
 * `comments_recording_timeline_idx` covers this query shape.
 */
export async function listCommentsByRecording(
  recordingId: string,
): Promise<Comment[]> {
  const { rows } = await getDb().query<CommentRow>(
    `SELECT id, recording_id, commenter_id, is_admin,
            body, timestamp_seconds, created_at
       FROM comments
      WHERE recording_id = $1
      ORDER BY timestamp_seconds ASC, created_at ASC`,
    [recordingId],
  );
  return rows.map(hydrateComment);
}

/**
 * Insert a new comment. Returns the hydrated comment including
 * the server-assigned created_at timestamp.
 */
export async function createComment(opts: {
  id: string;
  recordingId: string;
  commenterId: string | null;
  isAdmin: boolean;
  body: string;
  timestampSeconds: number;
}): Promise<Comment> {
  const { rows } = await getDb().query<CommentRow>(
    `INSERT INTO comments
       (id, recording_id, commenter_id, is_admin, body, timestamp_seconds)
     VALUES ($1, $2, $3, $4, $5, $6)
     RETURNING id, recording_id, commenter_id, is_admin,
               body, timestamp_seconds, created_at`,
    [
      opts.id,
      opts.recordingId,
      opts.commenterId,
      opts.isAdmin,
      opts.body,
      opts.timestampSeconds,
    ],
  );
  return hydrateComment(rows[0]);
}

/**
 * Fetch a single comment by id. Used to verify ownership before
 * delete and to confirm the comment belongs to the expected
 * recording.
 */
export async function getCommentById(
  commentId: string,
): Promise<Comment | null> {
  const { rows } = await getDb().query<CommentRow>(
    `SELECT id, recording_id, commenter_id, is_admin,
            body, timestamp_seconds, created_at
       FROM comments
      WHERE id = $1
      LIMIT 1`,
    [commentId],
  );
  const row = rows[0];
  if (!row) return null;
  return hydrateComment(row);
}

/**
 * Delete a comment by id. Returns true if a row was removed.
 */
export async function deleteComment(commentId: string): Promise<boolean> {
  const result = await getDb().query("DELETE FROM comments WHERE id = $1", [
    commentId,
  ]);
  return (result.rowCount ?? 0) > 0;
}

/**
 * Ensure a commenter row exists for the given id. Uses an upsert
 * so it's safe to call on every request — existing rows are left
 * untouched.
 */
export async function getOrCreateCommenter(id: string): Promise<void> {
  await getDb().query(
    "INSERT INTO commenters (id) VALUES ($1) ON CONFLICT (id) DO NOTHING",
    [id],
  );
}
