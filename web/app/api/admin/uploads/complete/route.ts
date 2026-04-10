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
import { completeRecording, getRecordingForCompletion } from "@/lib/db/queries";
import { jsonError } from "@/lib/http";
import { headRecordingObject, recordingShareUrl } from "@/lib/r2/client";

interface CompleteRequestBody {
  recordingId?: unknown;
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
  let row: { sizeBytes: number; status: string } | null;
  try {
    row = await getRecordingForCompletion(recordingId);
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

  if (head.size !== row.sizeBytes) {
    return jsonError(
      409,
      `R2 object size (${head.size}) does not match expected (${row.sizeBytes})`,
    );
  }

  // Flip status to 'complete'. Idempotent if already complete.
  try {
    await completeRecording(recordingId);
  } catch (err) {
    console.error("[uploads/complete] DB update failed:", err);
    return jsonError(500, "database error");
  }

  return Response.json({
    recordingId,
    shareUrl: recordingShareUrl(recordingId),
  });
}
