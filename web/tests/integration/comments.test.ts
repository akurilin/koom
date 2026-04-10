/**
 * Integration tests for the comment system API routes.
 *
 * Covers three endpoints:
 *
 *   GET  /api/public/recordings/[id]/comments         — list + identity
 *   POST /api/public/recordings/[id]/comments         — create
 *   DELETE /api/public/recordings/[id]/comments/[cid]  — delete
 *
 * Tests follow the same patterns as public-recordings.test.ts:
 * direct handler invocation with constructed Request objects, real
 * Postgres, afterEach cleanup. No mocking.
 *
 * The routes don't exist yet — these tests are written first (TDD).
 */

import { randomUUID } from "node:crypto";
import pg from "pg";
import { afterEach, describe, expect, it } from "vitest";

import {
  GET as commentsGET,
  POST as commentsPOST,
} from "@/app/api/public/recordings/[id]/comments/route";
import { DELETE as commentDELETE } from "@/app/api/public/recordings/[id]/comments/[commentId]/route";

const { Client: PgClient } = pg;

// ────────────────────────────────────────────────────────────────
// Shared state for cleanup
// ────────────────────────────────────────────────────────────────

const createdRecordingIds: string[] = [];
const createdCommentIds: string[] = [];
const createdCommenterIds: string[] = [];

afterEach(async () => {
  const databaseUrl = requireEnv("DATABASE_URL");
  const client = new PgClient({ connectionString: databaseUrl });
  await client.connect();
  try {
    // Comments first (FK to recordings via CASCADE, but explicit
    // cleanup is cleaner for commenter rows).
    if (createdCommentIds.length > 0) {
      await client.query("DELETE FROM comments WHERE id = ANY($1)", [
        createdCommentIds,
      ]);
    }
    if (createdCommenterIds.length > 0) {
      await client.query("DELETE FROM commenters WHERE id = ANY($1)", [
        createdCommenterIds,
      ]);
    }
    if (createdRecordingIds.length > 0) {
      await client.query("DELETE FROM recordings WHERE id = ANY($1)", [
        createdRecordingIds,
      ]);
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn(`[cleanup] DB delete failed: ${msg}`);
  } finally {
    await client.end();
    createdRecordingIds.length = 0;
    createdCommentIds.length = 0;
    createdCommenterIds.length = 0;
  }
});

// ────────────────────────────────────────────────────────────────
// GET /api/public/recordings/[id]/comments
// ────────────────────────────────────────────────────────────────

describe("GET /api/public/recordings/[id]/comments", () => {
  it("returns empty array for a recording with no comments", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const res = await callGET(recId);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.comments).toEqual([]);
  });

  it("sets koom-commenter cookie when absent", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const res = await callGET(recId);
    expect(res.status).toBe(200);

    const setCookie = res.headers.get("set-cookie");
    expect(setCookie).toBeTruthy();
    expect(setCookie).toContain("koom-commenter=");
    expect(setCookie).toContain("HttpOnly");
    expect(setCookie).toContain("SameSite=Lax");
    expect(setCookie).toContain("Max-Age=31536000");

    // Extract the commenter id for cleanup
    const match = setCookie!.match(/koom-commenter=([0-9a-f-]+)/);
    expect(match).toBeTruthy();
    createdCommenterIds.push(match![1]);
  });

  it("preserves existing cookie (no Set-Cookie when present)", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const res = await callGET(recId, { commenterId });
    expect(res.status).toBe(200);

    // Should not set a new cookie since one was provided
    const setCookie = res.headers.get("set-cookie");
    expect(setCookie).toBeNull();
  });

  it("returns comments sorted by timestamp_seconds ascending", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    // Insert out of order
    const id1 = randomUUID();
    const id2 = randomUUID();
    const id3 = randomUUID();
    await insertComment({
      id: id1,
      recordingId: recId,
      commenterId,
      body: "at 30",
      timestampSeconds: 30,
    });
    await insertComment({
      id: id2,
      recordingId: recId,
      commenterId,
      body: "at 10",
      timestampSeconds: 10,
    });
    await insertComment({
      id: id3,
      recordingId: recId,
      commenterId,
      body: "at 20",
      timestampSeconds: 20,
    });
    createdCommentIds.push(id1, id2, id3);

    const res = await callGET(recId, { commenterId });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.comments).toHaveLength(3);
    expect(body.comments[0].timestampSeconds).toBe(10);
    expect(body.comments[1].timestampSeconds).toBe(20);
    expect(body.comments[2].timestampSeconds).toBe(30);
  });

  it("returns 404 for a nonexistent recording", async () => {
    const res = await callGET(randomUUID());
    expect(res.status).toBe(404);
  });

  it("marks own comments with isOwn: true", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const commentId = randomUUID();
    await insertComment({
      id: commentId,
      recordingId: recId,
      commenterId,
      body: "mine",
      timestampSeconds: 5,
    });
    createdCommentIds.push(commentId);

    const res = await callGET(recId, { commenterId });
    const body = await res.json();
    expect(body.comments[0].isOwn).toBe(true);
  });

  it("does not mark other commenters' comments as own", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterA = randomUUID();
    const commenterB = randomUUID();
    await insertCommenter(commenterA);
    await insertCommenter(commenterB);
    createdCommenterIds.push(commenterA, commenterB);

    const commentId = randomUUID();
    await insertComment({
      id: commentId,
      recordingId: recId,
      commenterId: commenterA,
      body: "from A",
      timestampSeconds: 5,
    });
    createdCommentIds.push(commentId);

    // Request as commenter B
    const res = await callGET(recId, { commenterId: commenterB });
    const body = await res.json();
    expect(body.comments[0].isOwn).toBe(false);
  });
});

// ────────────────────────────────────────────────────────────────
// POST /api/public/recordings/[id]/comments
// ────────────────────────────────────────────────────────────────

describe("POST /api/public/recordings/[id]/comments", () => {
  it("creates an anonymous comment", async () => {
    const recId = randomUUID();
    await insertRecording({
      id: recId,
      status: "complete",
      durationSeconds: 120,
    });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const res = await callPOST(
      recId,
      { body: "nice video", timestampSeconds: 42.5 },
      { commenterId },
    );
    expect(res.status).toBe(201);

    const responseBody = await res.json();
    expect(responseBody.comment.body).toBe("nice video");
    expect(responseBody.comment.timestampSeconds).toBeCloseTo(42.5, 5);
    expect(responseBody.comment.isAdmin).toBe(false);
    expect(responseBody.comment.displayName).toBe(
      `Guest ${commenterId.slice(0, 4)}`,
    );

    createdCommentIds.push(responseBody.comment.id);
  });

  it("returns 401 when no cookie and no admin auth", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const res = await callPOST(recId, { body: "hello", timestampSeconds: 10 });
    expect(res.status).toBe(401);
  });

  it("creates an admin comment via bearer token", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const res = await callPOST(
      recId,
      { body: "admin note", timestampSeconds: 10 },
      { admin: true },
    );
    expect(res.status).toBe(201);

    const responseBody = await res.json();
    expect(responseBody.comment.isAdmin).toBe(true);
    expect(responseBody.comment.displayName).toBe("Admin");

    createdCommentIds.push(responseBody.comment.id);
  });

  it("admin auth takes precedence over commenter cookie", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const res = await callPOST(
      recId,
      { body: "admin wins", timestampSeconds: 5 },
      { admin: true, commenterId },
    );
    expect(res.status).toBe(201);

    const responseBody = await res.json();
    expect(responseBody.comment.isAdmin).toBe(true);

    createdCommentIds.push(responseBody.comment.id);
  });

  it("rejects empty body", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const res = await callPOST(
      recId,
      { body: "", timestampSeconds: 10 },
      { commenterId },
    );
    expect(res.status).toBe(400);
  });

  it("rejects body exceeding 2000 chars", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const longBody = "x".repeat(2001);
    const res = await callPOST(
      recId,
      { body: longBody, timestampSeconds: 10 },
      { commenterId },
    );
    expect(res.status).toBe(400);
  });

  it("rejects missing timestampSeconds", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const res = await callPOST(
      recId,
      { body: "no timestamp" } as Record<string, unknown>,
      { commenterId },
    );
    expect(res.status).toBe(400);
  });

  it("rejects negative timestampSeconds", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const res = await callPOST(
      recId,
      { body: "negative", timestampSeconds: -1 },
      { commenterId },
    );
    expect(res.status).toBe(400);
  });

  it("returns 404 for a nonexistent recording", async () => {
    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const res = await callPOST(
      randomUUID(),
      { body: "orphan", timestampSeconds: 10 },
      { commenterId },
    );
    expect(res.status).toBe(404);
  });
});

// ────────────────────────────────────────────────────────────────
// DELETE /api/public/recordings/[id]/comments/[commentId]
// ────────────────────────────────────────────────────────────────

describe("DELETE /api/public/recordings/[id]/comments/[commentId]", () => {
  it("anonymous commenter can delete own comment", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const commentId = randomUUID();
    await insertComment({
      id: commentId,
      recordingId: recId,
      commenterId,
      body: "mine",
      timestampSeconds: 5,
    });
    createdCommentIds.push(commentId);

    const res = await callDELETE(recId, commentId, { commenterId });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.ok).toBe(true);

    // Verify actually deleted
    const exists = await commentExistsInDb(commentId);
    expect(exists).toBe(false);
  });

  it("anonymous commenter cannot delete another's comment", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterA = randomUUID();
    const commenterB = randomUUID();
    await insertCommenter(commenterA);
    await insertCommenter(commenterB);
    createdCommenterIds.push(commenterA, commenterB);

    const commentId = randomUUID();
    await insertComment({
      id: commentId,
      recordingId: recId,
      commenterId: commenterA,
      body: "A's comment",
      timestampSeconds: 5,
    });
    createdCommentIds.push(commentId);

    // commenter B tries to delete A's comment
    const res = await callDELETE(recId, commentId, { commenterId: commenterB });
    expect(res.status).toBe(403);
  });

  it("admin can delete any comment", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const commentId = randomUUID();
    await insertComment({
      id: commentId,
      recordingId: recId,
      commenterId,
      body: "to be deleted",
      timestampSeconds: 5,
    });
    createdCommentIds.push(commentId);

    const res = await callDELETE(recId, commentId, { admin: true });
    expect(res.status).toBe(200);

    const exists = await commentExistsInDb(commentId);
    expect(exists).toBe(false);
  });

  it("returns 404 for a nonexistent comment", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    const res = await callDELETE(recId, randomUUID(), { commenterId });
    expect(res.status).toBe(404);
  });

  it("returns 401 with no cookie and no admin auth", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commentId = randomUUID();
    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);
    await insertComment({
      id: commentId,
      recordingId: recId,
      commenterId,
      body: "test",
      timestampSeconds: 5,
    });
    createdCommentIds.push(commentId);

    const res = await callDELETE(recId, commentId, {});
    expect(res.status).toBe(401);
  });

  it("anonymous cannot delete admin comment", async () => {
    const recId = randomUUID();
    await insertRecording({ id: recId, status: "complete" });
    createdRecordingIds.push(recId);

    const commenterId = randomUUID();
    await insertCommenter(commenterId);
    createdCommenterIds.push(commenterId);

    // Insert an admin comment (is_admin=true, commenter_id=null)
    const commentId = randomUUID();
    await insertAdminComment({
      id: commentId,
      recordingId: recId,
      body: "admin says",
      timestampSeconds: 5,
    });
    createdCommentIds.push(commentId);

    const res = await callDELETE(recId, commentId, { commenterId });
    expect(res.status).toBe(403);
  });
});

// ────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(
      `Test environment missing ${name}. Load web/.env.test.local and confirm the value is set.`,
    );
  }
  return v;
}

interface CallOpts {
  commenterId?: string;
  admin?: boolean;
}

function buildHeaders(opts: CallOpts): Record<string, string> {
  const headers: Record<string, string> = {};
  if (opts.admin) {
    headers["Authorization"] = `Bearer ${requireEnv("KOOM_ADMIN_SECRET")}`;
  }
  if (opts.commenterId) {
    headers["Cookie"] = `koom-commenter=${opts.commenterId}`;
  }
  return headers;
}

function callGET(recordingId: string, opts: CallOpts = {}): Promise<Response> {
  return commentsGET(
    new Request(
      `http://localhost/api/public/recordings/${recordingId}/comments`,
      {
        headers: buildHeaders(opts),
      },
    ),
    { params: Promise.resolve({ id: recordingId }) },
  );
}

function callPOST(
  recordingId: string,
  body: Record<string, unknown>,
  opts: CallOpts = {},
): Promise<Response> {
  const headers = { ...buildHeaders(opts), "Content-Type": "application/json" };
  return commentsPOST(
    new Request(
      `http://localhost/api/public/recordings/${recordingId}/comments`,
      {
        method: "POST",
        headers,
        body: JSON.stringify(body),
      },
    ),
    { params: Promise.resolve({ id: recordingId }) },
  );
}

function callDELETE(
  recordingId: string,
  commentId: string,
  opts: CallOpts = {},
): Promise<Response> {
  return commentDELETE(
    new Request(
      `http://localhost/api/public/recordings/${recordingId}/comments/${commentId}`,
      { method: "DELETE", headers: buildHeaders(opts) },
    ),
    { params: Promise.resolve({ id: recordingId, commentId }) },
  );
}

// ── DB helpers ───────────────────────────────────────────────────

interface InsertRecordingOpts {
  id: string;
  status: "pending" | "complete";
  durationSeconds?: number | null;
}

async function insertRecording(opts: InsertRecordingOpts): Promise<void> {
  const databaseUrl = requireEnv("DATABASE_URL");
  const r2Bucket = requireEnv("R2_BUCKET");
  const client = new PgClient({ connectionString: databaseUrl });
  await client.connect();
  try {
    await client.query(
      `INSERT INTO recordings
         (id, status, title, original_filename, duration_seconds,
          size_bytes, content_type, bucket, object_key)
       VALUES ($1, $2, null, 'test.mp4', $3, 1024, 'video/mp4', $4, $5)`,
      [
        opts.id,
        opts.status,
        opts.durationSeconds ?? null,
        r2Bucket,
        `recordings/${opts.id}/video.mp4`,
      ],
    );
  } finally {
    await client.end();
  }
}

async function insertCommenter(id: string): Promise<void> {
  const databaseUrl = requireEnv("DATABASE_URL");
  const client = new PgClient({ connectionString: databaseUrl });
  await client.connect();
  try {
    await client.query("INSERT INTO commenters (id) VALUES ($1)", [id]);
  } finally {
    await client.end();
  }
}

interface InsertCommentOpts {
  id: string;
  recordingId: string;
  commenterId: string;
  body: string;
  timestampSeconds: number;
}

async function insertComment(opts: InsertCommentOpts): Promise<void> {
  const databaseUrl = requireEnv("DATABASE_URL");
  const client = new PgClient({ connectionString: databaseUrl });
  await client.connect();
  try {
    await client.query(
      `INSERT INTO comments (id, recording_id, commenter_id, is_admin, body, timestamp_seconds)
       VALUES ($1, $2, $3, FALSE, $4, $5)`,
      [
        opts.id,
        opts.recordingId,
        opts.commenterId,
        opts.body,
        opts.timestampSeconds,
      ],
    );
  } finally {
    await client.end();
  }
}

interface InsertAdminCommentOpts {
  id: string;
  recordingId: string;
  body: string;
  timestampSeconds: number;
}

async function insertAdminComment(opts: InsertAdminCommentOpts): Promise<void> {
  const databaseUrl = requireEnv("DATABASE_URL");
  const client = new PgClient({ connectionString: databaseUrl });
  await client.connect();
  try {
    await client.query(
      `INSERT INTO comments (id, recording_id, commenter_id, is_admin, body, timestamp_seconds)
       VALUES ($1, $2, NULL, TRUE, $3, $4)`,
      [opts.id, opts.recordingId, opts.body, opts.timestampSeconds],
    );
  } finally {
    await client.end();
  }
}

async function commentExistsInDb(commentId: string): Promise<boolean> {
  const databaseUrl = requireEnv("DATABASE_URL");
  const client = new PgClient({ connectionString: databaseUrl });
  await client.connect();
  try {
    const { rows } = await client.query(
      "SELECT 1 FROM comments WHERE id = $1 LIMIT 1",
      [commentId],
    );
    return rows.length > 0;
  } finally {
    await client.end();
  }
}
