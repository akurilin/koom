/**
 * GET /api/admin/recordings
 *
 * Admin-only list endpoint powering the authenticated `/` page.
 * Returns every complete recording newest-first, with enough
 * metadata to render a list with previews and to click through to
 * the public watch page.
 *
 * Requires admin auth via EITHER the `Authorization: Bearer`
 * header (desktop client, tests) OR a valid session cookie set by
 * the browser login form.
 *
 * The response shape is the JSON-friendly projection of
 * `Recording` from `@/lib/db/queries` plus a fully-qualified
 * `videoUrl` built by the R2 client helper, so consumers don't
 * have to reconstruct URLs themselves.
 */

import { requireAdmin } from "@/lib/auth/admin";
import { listAllCompletedRecordings } from "@/lib/db/queries";
import {
  recordingPublicUrl,
  recordingThumbnailPublicUrl,
} from "@/lib/r2/client";

export async function GET(request: Request): Promise<Response> {
  const authError = await requireAdmin(request);
  if (authError) return authError;

  try {
    const recordings = await listAllCompletedRecordings();
    return Response.json({
      recordings: recordings.map((r) => ({
        recordingId: r.id,
        createdAt: r.createdAt.toISOString(),
        title: r.title,
        originalFilename: r.originalFilename,
        sizeBytes: r.sizeBytes,
        durationSeconds: r.durationSeconds,
        contentType: r.contentType,
        thumbnailUrl: recordingThumbnailPublicUrl(r.id),
        videoUrl: recordingPublicUrl(r.id),
      })),
    });
  } catch (err) {
    console.error("[admin/recordings] listing failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }
}
