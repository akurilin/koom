/**
 * GET  /api/public/recordings/[id]/comments — list comments
 * POST /api/public/recordings/[id]/comments — create a comment
 *
 * Both routes are public (no admin auth required to read or write).
 * Anonymous commenters are identified by a koom-commenter cookie;
 * the admin is identified by the existing requireAdmin() check.
 *
 * The GET handler has one unusual behavior: it creates a commenter
 * row and sets the cookie when the cookie is absent. This is a
 * deliberate choice — identity is established on first page view,
 * not deferred until the first comment POST. The DB write on GET
 * is acceptable at koom's single-tenant scale.
 */

import { randomUUID } from "node:crypto";

import { requireAdmin } from "@/lib/auth/admin";
import {
  getCommenterIdFromCookie,
  setCommenterCookie,
} from "@/lib/auth/commenter";
import {
  createComment,
  getOrCreateCommenter,
  listCommentsByRecording,
  type Comment,
} from "@/lib/db/comments";
import { getCompletedRecordingById } from "@/lib/db/queries";

interface RouteContext {
  params: Promise<{ id: string }>;
}

// ────────────────────────────────────────────────────────────────
// GET
// ────────────────────────────────────────────────────────────────

export async function GET(
  request: Request,
  ctx: RouteContext,
): Promise<Response> {
  const { id } = await ctx.params;

  // Verify recording exists
  let recording;
  try {
    recording = await getCompletedRecordingById(id);
  } catch (err) {
    console.error("[comments/GET] DB query failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }
  if (!recording) {
    return Response.json({ error: "recording not found" }, { status: 404 });
  }

  // Resolve commenter identity
  let commenterId = getCommenterIdFromCookie(request);
  let setCookieHeader: string | null = null;

  if (!commenterId) {
    commenterId = randomUUID();
    try {
      await getOrCreateCommenter(commenterId);
    } catch (err) {
      console.error("[comments/GET] commenter upsert failed:", err);
      return Response.json({ error: "database error" }, { status: 500 });
    }
    setCookieHeader = setCommenterCookie(commenterId);
  } else {
    // Idempotent upsert — handles stale cookies whose commenter
    // row was lost to a DB reset.
    try {
      await getOrCreateCommenter(commenterId);
    } catch (err) {
      console.error("[comments/GET] commenter upsert failed:", err);
      // Non-fatal — the listing still works, just isOwn might be wrong.
    }
  }

  // Check admin status
  const isAdmin = (await requireAdmin(request)) === null;

  // Fetch comments
  let comments: Comment[];
  try {
    comments = await listCommentsByRecording(id);
  } catch (err) {
    console.error("[comments/GET] listing failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }

  const payload = {
    comments: comments.map((c) => ({
      id: c.id,
      displayName: c.displayName,
      body: c.body,
      timestampSeconds: c.timestampSeconds,
      createdAt: c.createdAt.toISOString(),
      isAdmin: c.isAdmin,
      isOwn: c.isAdmin ? isAdmin : c.commenterId === commenterId,
    })),
    me: {
      kind: isAdmin ? "admin" : "anonymous",
      displayName: isAdmin ? "Admin" : `Guest ${commenterId.slice(0, 4)}`,
      commenterId: isAdmin ? null : commenterId,
      canDelete: isAdmin,
    },
  };

  const res = Response.json(payload);
  if (setCookieHeader) {
    res.headers.set("Set-Cookie", setCookieHeader);
  }
  return res;
}

// ────────────────────────────────────────────────────────────────
// POST
// ────────────────────────────────────────────────────────────────

export async function POST(
  request: Request,
  ctx: RouteContext,
): Promise<Response> {
  const { id } = await ctx.params;

  // Determine caller identity
  const isAdmin = (await requireAdmin(request)) === null;
  const commenterId = isAdmin ? null : getCommenterIdFromCookie(request);

  if (!isAdmin && !commenterId) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  // Verify recording exists
  let recording;
  try {
    recording = await getCompletedRecordingById(id);
  } catch (err) {
    console.error("[comments/POST] DB query failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }
  if (!recording) {
    return Response.json({ error: "recording not found" }, { status: 404 });
  }

  // Parse and validate body
  let raw: unknown;
  try {
    raw = await request.json();
  } catch {
    return Response.json({ error: "invalid JSON body" }, { status: 400 });
  }

  const validation = validateCommentBody(raw);
  if ("error" in validation) {
    return Response.json({ error: validation.error }, { status: 400 });
  }

  const { body, timestampSeconds } = validation;

  // Create comment
  let comment: Comment;
  try {
    comment = await createComment({
      id: randomUUID(),
      recordingId: id,
      commenterId: commenterId,
      isAdmin,
      body,
      timestampSeconds,
    });
  } catch (err) {
    console.error("[comments/POST] insert failed:", err);
    return Response.json({ error: "database error" }, { status: 500 });
  }

  return Response.json(
    {
      comment: {
        id: comment.id,
        displayName: comment.displayName,
        body: comment.body,
        timestampSeconds: comment.timestampSeconds,
        createdAt: comment.createdAt.toISOString(),
        isAdmin: comment.isAdmin,
        isOwn: true,
      },
    },
    { status: 201 },
  );
}

// ────────────────────────────────────────────────────────────────
// Validation
// ────────────────────────────────────────────────────────────────

interface ValidatedComment {
  body: string;
  timestampSeconds: number;
}

function validateCommentBody(
  raw: unknown,
): ValidatedComment | { error: string } {
  if (typeof raw !== "object" || raw === null) {
    return { error: "request body must be a JSON object" };
  }

  const obj = raw as Record<string, unknown>;

  // body
  if (typeof obj.body !== "string") {
    return { error: "body is required and must be a string" };
  }
  const body = obj.body.trim();
  if (body.length === 0) {
    return { error: "body must not be empty" };
  }
  if (body.length > 2000) {
    return { error: "body must not exceed 2000 characters" };
  }

  // timestampSeconds
  if (typeof obj.timestampSeconds !== "number") {
    return { error: "timestampSeconds is required and must be a number" };
  }
  if (!Number.isFinite(obj.timestampSeconds) || obj.timestampSeconds < 0) {
    return { error: "timestampSeconds must be a non-negative finite number" };
  }

  return { body, timestampSeconds: obj.timestampSeconds };
}
