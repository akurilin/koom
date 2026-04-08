/**
 * Integration test for GET /api/public/recordings/[id].
 *
 * Covers:
 *
 *   - 200 with the expected metadata shape for a complete recording.
 *   - 404 for an id that has no row at all.
 *   - 404 for a row that exists but is still `status = 'pending'`.
 *     (Security: mid-upload rows must never leak via the public API.
 *     Leaking them would let anyone probe upload state, and worse,
 *     hand out playback URLs before the object is actually in R2.)
 *   - Works with no Authorization header (the route is public).
 *
 * Unlike the upload test, this one does NOT touch R2. It inserts
 * rows directly into Postgres and calls the route handler with
 * constructed Request objects. The API just echoes back the public
 * URL string derived from R2_PUBLIC_BASE_URL and the object key;
 * verifying that the underlying R2 object actually exists is the
 * upload flow's job, not this endpoint's.
 */

import { randomUUID } from "node:crypto";
import pg from "pg";
import { afterEach, describe, expect, it } from "vitest";

import { GET as publicRecordingGET } from "@/app/api/public/recordings/[id]/route";

const { Client: PgClient } = pg;

interface InsertOpts {
  id: string;
  status: "pending" | "complete";
  title?: string | null;
  originalFilename?: string;
  sizeBytes?: number;
  durationSeconds?: number | null;
  contentType?: string;
  bucket?: string;
}

describe("GET /api/public/recordings/[id]", () => {
  const createdIds: string[] = [];

  afterEach(async () => {
    if (createdIds.length === 0) return;
    const databaseUrl = requireEnv("DATABASE_URL");
    const client = new PgClient({ connectionString: databaseUrl });
    await client.connect();
    try {
      await client.query("DELETE FROM recordings WHERE id = ANY($1)", [
        createdIds,
      ]);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn(`[cleanup] DB delete failed: ${msg}`);
    } finally {
      await client.end();
      createdIds.length = 0;
    }
  });

  it("returns metadata for a completed recording", async () => {
    const id = randomUUID();
    await insertRecording({
      id,
      status: "complete",
      title: "A test recording",
      originalFilename: "meeting.mp4",
      sizeBytes: 2_345_678,
      durationSeconds: 92.5,
    });
    createdIds.push(id);

    const res = await publicRecordingGET(
      new Request(`http://localhost/api/public/recordings/${id}`),
      { params: Promise.resolve({ id }) },
    );

    expect(res.status).toBe(200);

    const body = (await res.json()) as {
      recordingId: string;
      createdAt: string;
      title: string | null;
      videoUrl: string;
      durationSeconds: number | null;
      sizeBytes: number;
    };

    expect(body.recordingId).toBe(id);
    expect(body.title).toBe("A test recording");
    // BIGINT → number conversion is part of the contract
    expect(body.sizeBytes).toBe(2_345_678);
    expect(typeof body.sizeBytes).toBe("number");
    expect(body.durationSeconds).toBeCloseTo(92.5, 5);
    // createdAt should be an ISO-8601 string
    expect(body.createdAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
    // videoUrl should point at the R2 public base with the expected key
    const publicBase = requireEnv("R2_PUBLIC_BASE_URL").replace(/\/$/, "");
    expect(body.videoUrl).toBe(`${publicBase}/recordings/${id}/video.mp4`);
  });

  it("returns 404 for an id that does not exist", async () => {
    const id = randomUUID(); // never inserted

    const res = await publicRecordingGET(
      new Request(`http://localhost/api/public/recordings/${id}`),
      { params: Promise.resolve({ id }) },
    );

    expect(res.status).toBe(404);
  });

  it("returns 404 for a pending recording (does not leak mid-upload state)", async () => {
    const id = randomUUID();
    await insertRecording({ id, status: "pending" });
    createdIds.push(id);

    const res = await publicRecordingGET(
      new Request(`http://localhost/api/public/recordings/${id}`),
      { params: Promise.resolve({ id }) },
    );

    expect(res.status).toBe(404);
  });

  it("works without an Authorization header (public route)", async () => {
    const id = randomUUID();
    await insertRecording({ id, status: "complete" });
    createdIds.push(id);

    // Construct a Request with no headers at all. The route should
    // still respond 200 — this is the public endpoint, not an
    // admin one.
    const res = await publicRecordingGET(
      new Request(`http://localhost/api/public/recordings/${id}`),
      { params: Promise.resolve({ id }) },
    );

    expect(res.status).toBe(200);
  });
});

// ────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(
      `Test environment missing ${name}. Load web/.env.local and confirm the value is set.`,
    );
  }
  return v;
}

async function insertRecording(opts: InsertOpts): Promise<void> {
  const databaseUrl = requireEnv("DATABASE_URL");
  const r2Bucket = requireEnv("R2_BUCKET");

  const client = new PgClient({ connectionString: databaseUrl });
  await client.connect();
  try {
    await client.query(
      `INSERT INTO recordings
         (id, status, title, original_filename, duration_seconds,
          size_bytes, content_type, bucket, object_key)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
      [
        opts.id,
        opts.status,
        opts.title ?? null,
        opts.originalFilename ?? "test.mp4",
        opts.durationSeconds ?? null,
        opts.sizeBytes ?? 1024,
        opts.contentType ?? "video/mp4",
        opts.bucket ?? r2Bucket,
        `recordings/${opts.id}/video.mp4`,
      ],
    );
  } finally {
    await client.end();
  }
}
