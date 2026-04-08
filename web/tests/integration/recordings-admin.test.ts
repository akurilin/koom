/**
 * Integration tests for the admin recordings list and delete
 * endpoints:
 *
 *   GET    /api/admin/recordings
 *   DELETE /api/admin/recordings/[id]
 *
 * Both test groups call the route handlers directly with
 * constructed Request objects, use the `Authorization: Bearer`
 * transport (the cookie transport is verified by the Playwright
 * E2E test in round D-3), hit real local Postgres, and for the
 * delete tests, hit real Cloudflare R2 in the isolated test
 * bucket. All rows and R2 objects created are cleaned up in
 * afterEach regardless of test outcome.
 */

import {
  DeleteObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { randomUUID } from "node:crypto";
import pg from "pg";
import { afterEach, describe, expect, it } from "vitest";

import { DELETE as recordingDELETE } from "@/app/api/admin/recordings/[id]/route";
import { GET as recordingsGET } from "@/app/api/admin/recordings/route";

const { Client: PgClient } = pg;

// ────────────────────────────────────────────────────────────────────
// Shared helpers
// ────────────────────────────────────────────────────────────────────

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(
      `Test environment missing ${name}. Ensure npm run r2:setup:test has populated web/.env.test.local.`,
    );
  }
  return v;
}

function authHeaders(): Record<string, string> {
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${requireEnv("KOOM_ADMIN_SECRET")}`,
  };
}

function makeS3Client(): S3Client {
  return new S3Client({
    region: "auto",
    endpoint: `https://${requireEnv("R2_ACCOUNT_ID")}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: requireEnv("R2_ACCESS_KEY_ID"),
      secretAccessKey: requireEnv("R2_SECRET_ACCESS_KEY"),
    },
  });
}

interface InsertOpts {
  id: string;
  status: "pending" | "complete";
  title?: string | null;
  originalFilename?: string;
  sizeBytes?: number;
  durationSeconds?: number | null;
  createdAtOffsetSeconds?: number;
}

async function insertRecording(opts: InsertOpts): Promise<void> {
  const databaseUrl = requireEnv("DATABASE_URL");
  const r2Bucket = requireEnv("R2_BUCKET");

  const client = new PgClient({ connectionString: databaseUrl });
  await client.connect();
  try {
    // Optional created_at offset so tests can assert ordering
    // without relying on millisecond-precision wall clock.
    if (opts.createdAtOffsetSeconds !== undefined) {
      await client.query(
        `INSERT INTO recordings
           (id, created_at, status, title, original_filename,
            duration_seconds, size_bytes, content_type, bucket,
            object_key)
         VALUES ($1, now() + ($2 || ' seconds')::interval,
                 $3, $4, $5, $6, $7, $8, $9, $10)`,
        [
          opts.id,
          opts.createdAtOffsetSeconds.toString(),
          opts.status,
          opts.title ?? null,
          opts.originalFilename ?? "test.mp4",
          opts.durationSeconds ?? null,
          opts.sizeBytes ?? 1024,
          "video/mp4",
          r2Bucket,
          `recordings/${opts.id}/video.mp4`,
        ],
      );
    } else {
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
          "video/mp4",
          r2Bucket,
          `recordings/${opts.id}/video.mp4`,
        ],
      );
    }
  } finally {
    await client.end();
  }
}

async function deleteRows(ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  const client = new PgClient({
    connectionString: requireEnv("DATABASE_URL"),
  });
  await client.connect();
  try {
    await client.query("DELETE FROM recordings WHERE id = ANY($1)", [ids]);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn(`[cleanup] DB delete failed: ${msg}`);
  } finally {
    await client.end();
  }
}

async function deleteR2Object(bucket: string, key: string): Promise<void> {
  try {
    const s3 = makeS3Client();
    await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn(`[cleanup] R2 delete failed for ${key}: ${msg}`);
  }
}

// ────────────────────────────────────────────────────────────────────
// GET /api/admin/recordings
// ────────────────────────────────────────────────────────────────────

describe("GET /api/admin/recordings", () => {
  const createdIds: string[] = [];

  afterEach(async () => {
    if (createdIds.length > 0) {
      await deleteRows(createdIds);
      createdIds.length = 0;
    }
  });

  it("returns 401 without an Authorization header", async () => {
    const res = await recordingsGET(
      new Request("http://localhost/api/admin/recordings"),
    );
    expect(res.status).toBe(401);
  });

  it("returns 401 with a bogus bearer token", async () => {
    const res = await recordingsGET(
      new Request("http://localhost/api/admin/recordings", {
        headers: { Authorization: "Bearer absolutely-wrong-secret" },
      }),
    );
    expect(res.status).toBe(401);
  });

  it("returns completed recordings only, newest first", async () => {
    const suffix = Date.now();
    const oldId = randomUUID();
    const newId = randomUUID();
    const pendingId = randomUUID();

    await insertRecording({
      id: oldId,
      status: "complete",
      originalFilename: `koom_old_${suffix}.mp4`,
      sizeBytes: 2048,
      createdAtOffsetSeconds: -3600,
    });
    await insertRecording({
      id: newId,
      status: "complete",
      originalFilename: `koom_new_${suffix}.mp4`,
      sizeBytes: 4096,
      createdAtOffsetSeconds: 0,
    });
    await insertRecording({
      id: pendingId,
      status: "pending",
      originalFilename: `koom_pending_${suffix}.mp4`,
      sizeBytes: 8192,
      createdAtOffsetSeconds: 60,
    });
    createdIds.push(oldId, newId, pendingId);

    const res = await recordingsGET(
      new Request("http://localhost/api/admin/recordings", {
        headers: authHeaders(),
      }),
    );
    expect(res.status).toBe(200);

    const body = (await res.json()) as {
      recordings: Array<{
        recordingId: string;
        createdAt: string;
        originalFilename: string;
        sizeBytes: number;
        videoUrl: string;
      }>;
    };

    // Restrict to the rows we inserted — the test DB may contain
    // other rows from other test runs that happen in parallel
    // (it shouldn't today, but we want this to remain robust).
    const ours = body.recordings.filter((r) =>
      [oldId, newId, pendingId].includes(r.recordingId),
    );

    expect(ours.map((r) => r.recordingId)).toEqual([newId, oldId]);
    expect(ours[0]!.sizeBytes).toBe(4096);
    expect(typeof ours[0]!.sizeBytes).toBe("number");

    const publicBase = requireEnv("R2_PUBLIC_BASE_URL").replace(/\/$/, "");
    expect(ours[0]!.videoUrl).toBe(
      `${publicBase}/recordings/${newId}/video.mp4`,
    );
  });
});

// ────────────────────────────────────────────────────────────────────
// DELETE /api/admin/recordings/[id]
// ────────────────────────────────────────────────────────────────────

describe("DELETE /api/admin/recordings/[id]", () => {
  const createdIds: string[] = [];
  const createdR2Keys: string[] = [];

  afterEach(async () => {
    if (createdIds.length > 0) {
      await deleteRows(createdIds);
      createdIds.length = 0;
    }
    if (createdR2Keys.length > 0) {
      const bucket = requireEnv("R2_BUCKET");
      for (const key of createdR2Keys) {
        await deleteR2Object(bucket, key);
      }
      createdR2Keys.length = 0;
    }
  });

  it("returns 401 without an Authorization header", async () => {
    const id = randomUUID();
    const res = await recordingDELETE(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "DELETE",
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(401);
  });

  it("returns 404 for an id that does not exist", async () => {
    const id = randomUUID();
    const res = await recordingDELETE(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "DELETE",
        headers: authHeaders(),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(404);
  });

  it("removes both the database row and the R2 object", async () => {
    const id = randomUUID();
    const bucket = requireEnv("R2_BUCKET");
    const objectKey = `recordings/${id}/video.mp4`;

    // Seed a real R2 object for this recording so the DELETE
    // path exercises a non-trivial HEAD/DELETE cycle.
    await insertRecording({
      id,
      status: "complete",
      originalFilename: `koom_delete_test_${Date.now()}.mp4`,
      sizeBytes: 32,
    });
    createdIds.push(id);

    const s3 = makeS3Client();
    await s3.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: objectKey,
        Body: Buffer.from("small test bytes"),
        ContentType: "video/mp4",
      }),
    );
    // Safety net: add to cleanup in case the DELETE route fails
    // and leaves the object behind.
    createdR2Keys.push(objectKey);

    // Sanity: confirm the object really is there before we ask
    // the route to delete it.
    const headBefore = await s3.send(
      new HeadObjectCommand({ Bucket: bucket, Key: objectKey }),
    );
    expect(headBefore.ContentLength).toBe(16);

    // Act: call the DELETE handler.
    const res = await recordingDELETE(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "DELETE",
        headers: authHeaders(),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(200);

    // Assert: the row is gone.
    const dbClient = new PgClient({
      connectionString: requireEnv("DATABASE_URL"),
    });
    await dbClient.connect();
    try {
      const { rows } = await dbClient.query(
        "SELECT id FROM recordings WHERE id = $1",
        [id],
      );
      expect(rows).toHaveLength(0);
    } finally {
      await dbClient.end();
    }

    // Assert: the R2 object is gone. HEAD should return 404.
    let headNotFound = false;
    try {
      await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: objectKey }));
    } catch (err) {
      const e = err as {
        name?: string;
        $metadata?: { httpStatusCode?: number };
      };
      if (
        e.name === "NotFound" ||
        e.name === "NoSuchKey" ||
        e.$metadata?.httpStatusCode === 404
      ) {
        headNotFound = true;
      } else {
        throw err;
      }
    }
    expect(headNotFound).toBe(true);

    // Since the DELETE succeeded, drop the cleanup entry — the
    // afterEach would otherwise log a spurious warning trying to
    // delete an already-deleted object.
    createdR2Keys.length = 0;
    createdIds.length = 0;
  });
});
