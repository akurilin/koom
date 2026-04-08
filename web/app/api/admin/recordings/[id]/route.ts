/**
 * DELETE /api/admin/recordings/[id]
 *
 * Admin-only delete endpoint. Removes both the R2 object and the
 * Postgres row for a recording.
 *
 * Auth is the unified requireAdmin helper (bearer header OR
 * session cookie).
 *
 * Order of operations matters:
 *
 *   1. Verify the row exists (so we can return 404 cleanly).
 *   2. Delete the R2 object.
 *   3. Delete the row.
 *
 * Step 2 before step 3 means a partial failure (R2 delete succeeds
 * but row delete fails) leaves the row pointing at a missing
 * object — the UI will show a broken recording and the user can
 * retry the DELETE. Step 3 before step 2 would risk orphaning
 * the R2 object with no way to reach it from the app.
 *
 * S3 DeleteObject is idempotent — it succeeds even when the
 * target key does not exist — so retry-after-partial-failure is
 * safe.
 */

import { requireAdmin } from "@/lib/auth/admin";
import { deleteRecordingById, recordingExists } from "@/lib/db/queries";
import { deleteRecordingObject } from "@/lib/r2/client";

interface RouteContext {
  params: Promise<{ id: string }>;
}

export async function DELETE(
  request: Request,
  ctx: RouteContext,
): Promise<Response> {
  const authError = await requireAdmin(request);
  if (authError) return authError;

  const { id } = await ctx.params;
  if (!id) {
    return Response.json({ error: "recording id required" }, { status: 400 });
  }

  // 1. Does the row exist? We want a real 404 for unknown ids,
  //    not a confusing 200 after doing nothing useful.
  let exists: boolean;
  try {
    exists = await recordingExists(id);
  } catch (err) {
    console.error("[admin/recordings/delete] DB lookup failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }
  if (!exists) {
    return Response.json({ error: "recording not found" }, { status: 404 });
  }

  // 2. Delete the R2 object first, then the row. A failure between
  //    the two leaves a DB row pointing at a missing object — the
  //    watch page will show as broken, and the user can retry this
  //    DELETE to clean up.
  try {
    await deleteRecordingObject(id);
  } catch (err) {
    console.error("[admin/recordings/delete] R2 delete failed:", err);
    return Response.json(
      { error: "failed to delete R2 object" },
      { status: 500 },
    );
  }

  // 3. Delete the row.
  try {
    const removed = await deleteRecordingById(id);
    if (!removed) {
      // Race: somebody else already deleted the row between our
      // existence check and now. Treat it as success — the desired
      // end state is the same.
      return Response.json({ ok: true, alreadyGone: true });
    }
  } catch (err) {
    console.error("[admin/recordings/delete] DB delete failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }

  return Response.json({ ok: true });
}
