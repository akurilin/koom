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

import {
  DELETE as recordingDELETE,
  PATCH as recordingPATCH,
} from "@/app/api/admin/recordings/[id]/route";
import { PUT as thumbnailPUT } from "@/app/api/admin/recordings/[id]/thumbnail/route";
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
        thumbnailUrl: string;
        videoUrl: string;
      }>;
    };

    // Restrict to the rows we inserted — the test DB may contain
    // other rows from other test runs that happen in parallel
    // (it shouldn't today, but we want this to remain robust).
    const ours = body.recordings.filter((r) =>
      ([oldId, newId, pendingId] as string[]).includes(r.recordingId),
    );

    expect(ours.map((r) => r.recordingId)).toEqual([newId, oldId]);
    expect(ours[0]!.sizeBytes).toBe(4096);
    expect(typeof ours[0]!.sizeBytes).toBe("number");

    const publicBase = requireEnv("R2_PUBLIC_BASE_URL").replace(/\/$/, "");
    expect(ours[0]!.videoUrl).toBe(
      `${publicBase}/recordings/${newId}/video.mp4`,
    );
    expect(ours[0]!.thumbnailUrl).toBe(
      `${publicBase}/recordings/${newId}/thumbnail-v1.jpg`,
    );
  });
});

// ────────────────────────────────────────────────────────────────────
// PUT /api/admin/recordings/[id]/thumbnail
// ────────────────────────────────────────────────────────────────────

describe("PUT /api/admin/recordings/[id]/thumbnail", () => {
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
    const res = await thumbnailPUT(
      new Request(`http://localhost/api/admin/recordings/${id}/thumbnail`, {
        method: "PUT",
        headers: { "Content-Type": "image/jpeg" },
        body: Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(401);
  });

  it("returns 404 for an id that does not exist", async () => {
    const id = randomUUID();
    const res = await thumbnailPUT(
      new Request(`http://localhost/api/admin/recordings/${id}/thumbnail`, {
        method: "PUT",
        headers: {
          Authorization: authHeaders().Authorization,
          "Content-Type": "image/jpeg",
        },
        body: Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(404);
  });

  it("stores the sidecar thumbnail in R2", async () => {
    const id = randomUUID();
    const bucket = requireEnv("R2_BUCKET");
    const objectKey = `recordings/${id}/thumbnail-v1.jpg`;

    await insertRecording({
      id,
      status: "complete",
      originalFilename: `koom_thumbnail_${Date.now()}.mp4`,
    });
    createdIds.push(id);
    createdR2Keys.push(objectKey);

    const jpegBytes = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
    const res = await thumbnailPUT(
      new Request(`http://localhost/api/admin/recordings/${id}/thumbnail`, {
        method: "PUT",
        headers: {
          Authorization: authHeaders().Authorization,
          "Content-Type": "image/jpeg",
        },
        body: jpegBytes,
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(200);

    const body = (await res.json()) as { ok: boolean; thumbnailUrl: string };
    expect(body.ok).toBe(true);
    expect(body.thumbnailUrl).toBe(
      `${requireEnv("R2_PUBLIC_BASE_URL").replace(/\/$/, "")}/recordings/${id}/thumbnail-v1.jpg`,
    );

    const s3 = makeS3Client();
    const head = await s3.send(
      new HeadObjectCommand({ Bucket: bucket, Key: objectKey }),
    );
    expect(head.ContentLength).toBe(jpegBytes.length);
    expect(head.ContentType).toBe("image/jpeg");
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

  it("removes the database row, the R2 video, and the sidecar thumbnail", async () => {
    const id = randomUUID();
    const bucket = requireEnv("R2_BUCKET");
    const objectKey = `recordings/${id}/video.mp4`;
    const thumbnailKey = `recordings/${id}/thumbnail-v1.jpg`;

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
    await s3.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: thumbnailKey,
        Body: Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
        ContentType: "image/jpeg",
      }),
    );
    // Safety net: add to cleanup in case the DELETE route fails
    // and leaves the object behind.
    createdR2Keys.push(objectKey);
    createdR2Keys.push(thumbnailKey);

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

    let thumbnailNotFound = false;
    try {
      await s3.send(
        new HeadObjectCommand({ Bucket: bucket, Key: thumbnailKey }),
      );
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
        thumbnailNotFound = true;
      } else {
        throw err;
      }
    }
    expect(thumbnailNotFound).toBe(true);

    // Since the DELETE succeeded, drop the cleanup entry — the
    // afterEach would otherwise log a spurious warning trying to
    // delete an already-deleted object.
    createdR2Keys.length = 0;
    createdIds.length = 0;
  });
});

// ────────────────────────────────────────────────────────────────────
// PATCH /api/admin/recordings/[id]
// ────────────────────────────────────────────────────────────────────

describe("PATCH /api/admin/recordings/[id]", () => {
  const createdIds: string[] = [];

  afterEach(async () => {
    if (createdIds.length > 0) {
      await deleteRows(createdIds);
      createdIds.length = 0;
    }
  });

  async function readTitle(id: string): Promise<string | null> {
    const client = new PgClient({
      connectionString: requireEnv("DATABASE_URL"),
    });
    await client.connect();
    try {
      const { rows } = await client.query<{ title: string | null }>(
        "SELECT title FROM recordings WHERE id = $1",
        [id],
      );
      return rows[0]?.title ?? null;
    } finally {
      await client.end();
    }
  }

  it("returns 401 without an Authorization header", async () => {
    const id = randomUUID();
    const res = await recordingPATCH(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title: "hello" }),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(401);
  });

  it("returns 404 for an id that does not exist", async () => {
    const id = randomUUID();
    const res = await recordingPATCH(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "PATCH",
        headers: authHeaders(),
        body: JSON.stringify({ title: "nope" }),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(404);
  });

  it("rejects a body that does not include a title field", async () => {
    const id = randomUUID();
    await insertRecording({
      id,
      status: "complete",
      originalFilename: `koom_patch_missing_${Date.now()}.mp4`,
    });
    createdIds.push(id);

    const res = await recordingPATCH(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "PATCH",
        headers: authHeaders(),
        body: JSON.stringify({}),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(400);
  });

  it("rejects a non-string, non-null title", async () => {
    const id = randomUUID();
    await insertRecording({
      id,
      status: "complete",
      originalFilename: `koom_patch_badtype_${Date.now()}.mp4`,
    });
    createdIds.push(id);

    const res = await recordingPATCH(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "PATCH",
        headers: authHeaders(),
        body: JSON.stringify({ title: 42 }),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(400);
  });

  it("writes a trimmed title onto the row", async () => {
    const id = randomUUID();
    await insertRecording({
      id,
      status: "complete",
      title: null,
      originalFilename: `koom_patch_ok_${Date.now()}.mp4`,
    });
    createdIds.push(id);

    const res = await recordingPATCH(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "PATCH",
        headers: authHeaders(),
        body: JSON.stringify({ title: "  Kickoff meeting notes  " }),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(200);

    const body = (await res.json()) as { ok: boolean; title: string | null };
    expect(body.ok).toBe(true);
    expect(body.title).toBe("Kickoff meeting notes");

    expect(await readTitle(id)).toBe("Kickoff meeting notes");
  });

  it("treats an empty/whitespace title as a clear", async () => {
    const id = randomUUID();
    await insertRecording({
      id,
      status: "complete",
      title: "Old title",
      originalFilename: `koom_patch_clear_${Date.now()}.mp4`,
    });
    createdIds.push(id);

    const res = await recordingPATCH(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "PATCH",
        headers: authHeaders(),
        body: JSON.stringify({ title: "   " }),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(200);

    const body = (await res.json()) as { ok: boolean; title: string | null };
    expect(body.title).toBeNull();
    expect(await readTitle(id)).toBeNull();
  });

  it("accepts explicit null to clear the title", async () => {
    const id = randomUUID();
    await insertRecording({
      id,
      status: "complete",
      title: "Will be cleared",
      originalFilename: `koom_patch_null_${Date.now()}.mp4`,
    });
    createdIds.push(id);

    const res = await recordingPATCH(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "PATCH",
        headers: authHeaders(),
        body: JSON.stringify({ title: null }),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(200);
    expect(await readTitle(id)).toBeNull();
  });

  it("allows patching a pending (mid-upload) row so the auto-titler can land early", async () => {
    const id = randomUUID();
    await insertRecording({
      id,
      status: "pending",
      title: null,
      originalFilename: `koom_patch_pending_${Date.now()}.mp4`,
    });
    createdIds.push(id);

    const res = await recordingPATCH(
      new Request(`http://localhost/api/admin/recordings/${id}`, {
        method: "PATCH",
        headers: authHeaders(),
        body: JSON.stringify({ title: "Generated early" }),
      }),
      { params: Promise.resolve({ id }) },
    );
    expect(res.status).toBe(200);
    expect(await readTitle(id)).toBe("Generated early");
  });
});
