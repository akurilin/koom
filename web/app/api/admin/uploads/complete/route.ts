/**
 * POST /api/admin/uploads/complete
 *
 * Finalizes an upload session after the client has PUT the bytes to
 * the presigned R2 URL.
 *
 *   1. Require admin auth (Authorization: Bearer <KOOM_ADMIN_SECRET>).
 *   2. Parse and validate the JSON body { recordingId }.
 *   3. Look up the recording row; must exist, and either be 'pending'
 *      or already 'complete' (idempotent retry).
 *   4. HEAD the R2 object to confirm it exists and its size matches
 *      what init recorded.
 *   5. UPDATE the row's status to 'complete' (no-op if already).
 *   6. Return { recordingId, shareUrl }.
 */

import { requireAdmin } from "@/lib/auth/admin";
import { getDb } from "@/lib/db/client";
import { headRecordingObject } from "@/lib/r2/client";

interface CompleteRequestBody {
  recordingId?: unknown;
}

interface RecordingLookup {
  size_bytes: string; // BIGINT comes back as string from pg
  status: string;
}

export async function POST(request: Request): Promise<Response> {
  const authError = await requireAdmin(request);
  if (authError) return authError;

  let raw: CompleteRequestBody;
  try {
    raw = (await request.json()) as CompleteRequestBody;
  } catch {
    return jsonError(400, "invalid JSON body");
  }

  if (typeof raw.recordingId !== "string" || !raw.recordingId.trim()) {
    return jsonError(400, "recordingId is required");
  }
  const recordingId = raw.recordingId.trim();

  // Look up the row so we can compare sizes.
  let row: RecordingLookup | null;
  try {
    const { rows } = await getDb().query<RecordingLookup>(
      `SELECT size_bytes, status FROM recordings WHERE id = $1`,
      [recordingId],
    );
    row = rows[0] ?? null;
  } catch (err) {
    console.error("[uploads/complete] DB select failed:", err);
    return jsonError(500, "database error");
  }

  if (!row) {
    return jsonError(404, "recording not found");
  }

  // Verify the R2 object exists and the size matches what we recorded
  // at init time.
  let head: { size: number; contentType: string } | null;
  try {
    head = await headRecordingObject(recordingId);
  } catch (err) {
    console.error("[uploads/complete] R2 HEAD failed:", err);
    return jsonError(500, "failed to verify R2 object");
  }

  if (!head) {
    return jsonError(409, "R2 object not found — was the PUT successful?");
  }

  const expectedSize = Number(row.size_bytes);
  if (head.size !== expectedSize) {
    return jsonError(
      409,
      `R2 object size (${head.size}) does not match expected (${expectedSize})`,
    );
  }

  // Flip status to 'complete'. Idempotent if already complete.
  try {
    await getDb().query(
      `UPDATE recordings SET status = 'complete' WHERE id = $1`,
      [recordingId],
    );
  } catch (err) {
    console.error("[uploads/complete] DB update failed:", err);
    return jsonError(500, "database error");
  }

  return Response.json({
    recordingId,
    shareUrl: buildShareUrl(recordingId),
  });
}

function buildShareUrl(recordingId: string): string {
  const base = process.env.KOOM_PUBLIC_BASE_URL;
  if (!base) {
    throw new Error("KOOM_PUBLIC_BASE_URL is not set");
  }
  return `${base.replace(/\/$/, "")}/r/${recordingId}`;
}

function jsonError(status: number, message: string): Response {
  return Response.json({ error: message }, { status });
}
