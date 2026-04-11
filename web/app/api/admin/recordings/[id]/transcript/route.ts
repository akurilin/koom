/**
 * PUT /api/admin/recordings/[id]/transcript
 *
 * Admin-only sidecar transcript upload endpoint. Accepts a JSON
 * request body containing word-level timestamps from the desktop
 * client's WhisperKit pipeline and stores it in R2 at the
 * deterministic key `recordings/{id}/transcript.json`.
 *
 * The transcript is best-effort metadata — there is no database
 * column for it. The web UI fetches the public R2 URL directly
 * and falls back to "no transcript" if the object does not exist.
 */

import { requireAdmin } from "@/lib/auth/admin";
import { recordingExists } from "@/lib/db/queries";
import {
  putRecordingTranscript,
  recordingTranscriptPublicUrl,
} from "@/lib/r2/client";

interface RouteContext {
  params: Promise<{ id: string }>;
}

const TRANSCRIPT_MAX_BYTES = 10 * 1024 * 1024;

export async function PUT(
  request: Request,
  ctx: RouteContext,
): Promise<Response> {
  const authError = await requireAdmin(request);
  if (authError) return authError;

  const { id } = await ctx.params;
  if (!id) {
    return Response.json({ error: "recording id required" }, { status: 400 });
  }

  const contentType = request.headers
    .get("content-type")
    ?.split(";")[0]
    .trim()
    .toLowerCase();
  if (!contentType || contentType !== "application/json") {
    return Response.json(
      { error: "transcript upload must use Content-Type: application/json" },
      { status: 415 },
    );
  }

  let exists: boolean;
  try {
    exists = await recordingExists(id);
  } catch (err) {
    console.error("[admin/recordings/transcript] DB lookup failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }
  if (!exists) {
    return Response.json({ error: "recording not found" }, { status: 404 });
  }

  let body: Uint8Array;
  try {
    body = new Uint8Array(await request.arrayBuffer());
  } catch {
    return Response.json({ error: "invalid request body" }, { status: 400 });
  }

  if (body.byteLength === 0) {
    return Response.json(
      { error: "transcript body must not be empty" },
      { status: 400 },
    );
  }
  if (body.byteLength > TRANSCRIPT_MAX_BYTES) {
    return Response.json(
      {
        error: `transcript body must be ${TRANSCRIPT_MAX_BYTES} bytes or smaller`,
      },
      { status: 413 },
    );
  }

  try {
    await putRecordingTranscript(id, body);
  } catch (err) {
    console.error("[admin/recordings/transcript] R2 upload failed:", err);
    return Response.json(
      { error: "failed to store transcript" },
      { status: 500 },
    );
  }

  return Response.json({
    ok: true,
    transcriptUrl: recordingTranscriptPublicUrl(id),
  });
}
