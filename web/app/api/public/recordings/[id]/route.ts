/**
 * GET /api/public/recordings/[id]
 *
 * Public metadata endpoint for a single recording. Returns enough
 * information to render a watch page — including the direct R2
 * playback URL — without exposing any admin-only details.
 *
 * - No authentication.
 * - Filters to `status = 'complete'`: pending recordings return 404
 *   so mid-upload rows never leak into public surfaces.
 * - Returns 404 for missing recordings (same shape as pending so
 *   anyone probing cannot distinguish "does not exist" from
 *   "exists but not ready").
 */

import { getCompletedRecordingById } from "@/lib/db/queries";
import { recordingPublicUrl } from "@/lib/r2/client";

interface RouteContext {
  params: Promise<{ id: string }>;
}

export async function GET(
  _request: Request,
  ctx: RouteContext,
): Promise<Response> {
  const { id } = await ctx.params;

  if (!id) {
    return Response.json({ error: "recording not found" }, { status: 404 });
  }

  let recording;
  try {
    recording = await getCompletedRecordingById(id);
  } catch (err) {
    console.error("[public/recordings] DB query failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }

  if (!recording) {
    return Response.json({ error: "recording not found" }, { status: 404 });
  }

  return Response.json({
    recordingId: recording.id,
    createdAt: recording.createdAt.toISOString(),
    title: recording.title,
    videoUrl: recordingPublicUrl(recording.id),
    durationSeconds: recording.durationSeconds,
    sizeBytes: recording.sizeBytes,
  });
}
