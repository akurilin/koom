/**
 * DELETE /api/public/recordings/[id]/comments/[commentId]
 *
 * Delete a comment. Two auth paths:
 *
 *   1. Admin (bearer or session) — can delete any comment.
 *   2. Anonymous (koom-commenter cookie) — can only delete their
 *      own comments (commenter_id must match the cookie).
 *
 * Returns 404 for a missing comment or a comment that doesn't
 * belong to the specified recording (prevents cross-recording
 * delete via URL manipulation).
 */

import { requireAdmin } from "@/lib/auth/admin";
import { getCommenterIdFromCookie } from "@/lib/auth/commenter";
import { deleteComment, getCommentById } from "@/lib/db/comments";

interface RouteContext {
  params: Promise<{ id: string; commentId: string }>;
}

export async function DELETE(
  request: Request,
  ctx: RouteContext,
): Promise<Response> {
  const { id, commentId } = await ctx.params;

  // Fetch the comment first to verify it exists and belongs to
  // this recording.
  let comment;
  try {
    comment = await getCommentById(commentId);
  } catch (err) {
    console.error("[comments/DELETE] DB query failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }

  if (!comment || comment.recordingId !== id) {
    return Response.json({ error: "comment not found" }, { status: 404 });
  }

  // Check admin first — admin can delete any comment.
  const isAdmin = (await requireAdmin(request)) === null;
  if (isAdmin) {
    try {
      await deleteComment(commentId);
    } catch (err) {
      console.error("[comments/DELETE] delete failed:", err);
      return Response.json({ error: "database error" }, { status: 500 });
    }
    return Response.json({ ok: true });
  }

  // Anonymous path — cookie required.
  const cookieCommenterId = getCommenterIdFromCookie(request);
  if (!cookieCommenterId) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  // Must own the comment.
  if (comment.commenterId !== cookieCommenterId) {
    return Response.json({ error: "forbidden" }, { status: 403 });
  }

  try {
    await deleteComment(commentId);
  } catch (err) {
    console.error("[comments/DELETE] delete failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }

  return Response.json({ ok: true });
}
