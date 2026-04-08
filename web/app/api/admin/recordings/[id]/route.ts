/**
 * Admin-only endpoints for a single recording:
 *
 *   DELETE /api/admin/recordings/[id]   — remove R2 object + row
 *   PATCH  /api/admin/recordings/[id]   — update editable metadata
 *
 * Both use the unified `requireAdmin` helper (bearer header OR
 * session cookie).
 *
 * DELETE order of operations matters:
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
 *
 * PATCH is scoped to editable metadata only. For v1 that's just
 * the `title` column, written by both the desktop auto-titler and
 * (in a future round) a user-facing rename affordance.
 */

import { requireAdmin } from "@/lib/auth/admin";
import {
  deleteRecordingById,
  recordingExists,
  updateRecordingTitle,
} from "@/lib/db/queries";
import { deleteRecordingObject } from "@/lib/r2/client";

interface RouteContext {
  params: Promise<{ id: string }>;
}

// Cap titles at something sensible so we don't let a runaway LLM
// output a 50 kB title into the database. The Swift client clamps
// to 10 words client-side, so this is a belt-and-suspenders guard
// for any other caller of the PATCH endpoint.
const TITLE_MAX_LENGTH = 200;

interface PatchRequestBody {
  title?: unknown;
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

export async function PATCH(
  request: Request,
  ctx: RouteContext,
): Promise<Response> {
  const authError = await requireAdmin(request);
  if (authError) return authError;

  const { id } = await ctx.params;
  if (!id) {
    return Response.json({ error: "recording id required" }, { status: 400 });
  }

  let raw: PatchRequestBody;
  try {
    raw = (await request.json()) as PatchRequestBody;
  } catch {
    return Response.json({ error: "invalid JSON body" }, { status: 400 });
  }

  // v1 only accepts `title`. If the field is absent entirely,
  // there is nothing to update and the caller is confused.
  if (!("title" in raw)) {
    return Response.json(
      { error: "body must include a 'title' field" },
      { status: 400 },
    );
  }

  let title: string | null;
  if (raw.title === null) {
    title = null;
  } else if (typeof raw.title === "string") {
    const trimmed = raw.title.trim();
    if (trimmed.length > TITLE_MAX_LENGTH) {
      return Response.json(
        {
          error: `title must be ${TITLE_MAX_LENGTH} characters or fewer`,
        },
        { status: 400 },
      );
    }
    // Treat an empty/whitespace-only string as an explicit clear,
    // which matches how the init route normalizes titles.
    title = trimmed === "" ? null : trimmed;
  } else {
    return Response.json(
      { error: "title must be a string or null" },
      { status: 400 },
    );
  }

  let updated: boolean;
  try {
    updated = await updateRecordingTitle(id, title);
  } catch (err) {
    console.error("[admin/recordings/patch] DB update failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }

  if (!updated) {
    return Response.json({ error: "recording not found" }, { status: 404 });
  }

  return Response.json({ ok: true, title });
}
