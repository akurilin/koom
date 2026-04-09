/**
 * PUT /api/admin/recordings/[id]/thumbnail
 *
 * Admin-only sidecar thumbnail upload endpoint. Accepts a small
 * `image/jpeg` request body from the desktop client and stores it in
 * R2 at the deterministic key `recordings/{id}/thumbnail-v1.jpg`.
 *
 * The thumbnail is best-effort metadata, not part of the recording's
 * core lifecycle, so there is no database column for it. The web UI
 * derives the public URL by convention and falls back to the video's
 * first frame if the sidecar object does not exist.
 */

import { requireAdmin } from "@/lib/auth/admin";
import { recordingExists } from "@/lib/db/queries";
import {
  putRecordingThumbnail,
  recordingThumbnailPublicUrl,
} from "@/lib/r2/client";

interface RouteContext {
  params: Promise<{ id: string }>;
}

const THUMBNAIL_MAX_BYTES = 5 * 1024 * 1024;
const ACCEPTED_CONTENT_TYPES = new Set(["image/jpeg", "image/jpg"]);

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
  if (!contentType || !ACCEPTED_CONTENT_TYPES.has(contentType)) {
    return Response.json(
      { error: "thumbnail upload must use Content-Type: image/jpeg" },
      { status: 415 },
    );
  }

  let exists: boolean;
  try {
    exists = await recordingExists(id);
  } catch (err) {
    console.error("[admin/recordings/thumbnail] DB lookup failed:", err);
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
      { error: "thumbnail body must not be empty" },
      { status: 400 },
    );
  }
  if (body.byteLength > THUMBNAIL_MAX_BYTES) {
    return Response.json(
      {
        error: `thumbnail body must be ${THUMBNAIL_MAX_BYTES} bytes or smaller`,
      },
      { status: 413 },
    );
  }

  try {
    await putRecordingThumbnail(id, body);
  } catch (err) {
    console.error("[admin/recordings/thumbnail] R2 upload failed:", err);
    return Response.json(
      { error: "failed to store thumbnail" },
      { status: 500 },
    );
  }

  return Response.json({
    ok: true,
    thumbnailUrl: recordingThumbnailPublicUrl(id),
  });
}
