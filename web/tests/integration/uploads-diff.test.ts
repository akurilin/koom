/**
 * Integration test for POST /api/admin/uploads/diff.
 *
 * Two test groups:
 *
 *   1. Focused scenarios: empty list, all present, all missing,
 *      mixed, pending-not-counted, deduping, unauthorized, malformed
 *      body. These insert rows directly into Postgres and call the
 *      route handler with constructed Request objects — no R2.
 *
 *   2. Catch-up simulation: runs the real init -> PUT -> complete
 *      flow (same code path as upload.test.ts) for ONE file against
 *      real Cloudflare R2, inserts a second "already uploaded" row
 *      directly, then calls diff with a mixed list containing both
 *      plus one unknown. Asserts the partition matches what the
 *      desktop client's catch-up feature should see. Cleans up R2
 *      object + all DB rows in finally.
 *
 * This second group is what the user asked for: a test that
 * exercises the catch-up path end-to-end "without actually
 * involving the Swift client" — it simulates exactly what the
 * client will do, using TypeScript against the real web stack.
 */

import {
  DeleteObjectCommand,
  HeadObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { afterEach, describe, expect, it } from "vitest";

import { POST as completePOST } from "@/app/api/admin/uploads/complete/route";
import { POST as diffPOST } from "@/app/api/admin/uploads/diff/route";
import { POST as initPOST } from "@/app/api/admin/uploads/init/route";

const { Client: PgClient } = pg;

const thisDir = resolve(fileURLToPath(import.meta.url), "..");
const FIXTURE_PATH = resolve(thisDir, "..", "fixtures", "sample.mp4");

// ────────────────────────────────────────────────────────────────────
// Focused scenarios
// ────────────────────────────────────────────────────────────────────

describe("POST /api/admin/uploads/diff", () => {
  const createdIds: string[] = [];

  afterEach(async () => {
    if (createdIds.length === 0) return;
    await deleteRecordingsByIds(createdIds);
    createdIds.length = 0;
  });

  it("returns empty arrays for an empty filenames list", async () => {
    const res = await callDiff({ filenames: [] });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toEqual({ uploaded: [], missing: [] });
  });

  it("returns all filenames as missing when none are in the DB", async () => {
    const filenames = [
      `koom_test_${Date.now()}_a.mp4`,
      `koom_test_${Date.now()}_b.mp4`,
    ];
    const res = await callDiff({ filenames });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      uploaded: string[];
      missing: string[];
    };
    expect(body.uploaded).toEqual([]);
    expect(body.missing.sort()).toEqual(filenames.sort());
  });

  it("returns all filenames as uploaded when every row is complete", async () => {
    const suffix = Date.now();
    const filenames = [
      `koom_all_present_${suffix}_a.mp4`,
      `koom_all_present_${suffix}_b.mp4`,
    ];

    for (const filename of filenames) {
      const id = randomUUID();
      await insertRecording({
        id,
        status: "complete",
        originalFilename: filename,
      });
      createdIds.push(id);
    }

    const res = await callDiff({ filenames });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      uploaded: string[];
      missing: string[];
    };
    expect(body.uploaded.sort()).toEqual(filenames.sort());
    expect(body.missing).toEqual([]);
  });

  it("partitions mixed present/missing filenames correctly", async () => {
    const suffix = Date.now();
    const presentFilename = `koom_mix_${suffix}_present.mp4`;
    const missingFilename = `koom_mix_${suffix}_missing.mp4`;

    const id = randomUUID();
    await insertRecording({
      id,
      status: "complete",
      originalFilename: presentFilename,
    });
    createdIds.push(id);

    const res = await callDiff({
      filenames: [presentFilename, missingFilename],
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      uploaded: string[];
      missing: string[];
    };
    expect(body.uploaded).toEqual([presentFilename]);
    expect(body.missing).toEqual([missingFilename]);
  });

  it("does not count pending recordings as uploaded", async () => {
    const suffix = Date.now();
    const pendingFilename = `koom_pending_${suffix}.mp4`;

    const id = randomUUID();
    await insertRecording({
      id,
      status: "pending",
      originalFilename: pendingFilename,
    });
    createdIds.push(id);

    const res = await callDiff({ filenames: [pendingFilename] });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      uploaded: string[];
      missing: string[];
    };
    // Pending must appear in missing so the catch-up retries it.
    expect(body.uploaded).toEqual([]);
    expect(body.missing).toEqual([pendingFilename]);
  });

  it("dedupes duplicate filenames in the request", async () => {
    const suffix = Date.now();
    const filename = `koom_dupe_${suffix}.mp4`;

    const id = randomUUID();
    await insertRecording({
      id,
      status: "complete",
      originalFilename: filename,
    });
    createdIds.push(id);

    const res = await callDiff({
      filenames: [filename, filename, filename],
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      uploaded: string[];
      missing: string[];
    };
    expect(body.uploaded).toEqual([filename]);
    expect(body.missing).toEqual([]);
  });

  it("rejects requests with no Authorization header as 401", async () => {
    const res = await diffPOST(
      new Request("http://localhost/api/admin/uploads/diff", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ filenames: [] }),
      }),
    );
    expect(res.status).toBe(401);
  });

  it("rejects requests with a wrong bearer token as 401", async () => {
    const res = await diffPOST(
      new Request("http://localhost/api/admin/uploads/diff", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer this-is-definitely-not-the-right-secret",
        },
        body: JSON.stringify({ filenames: [] }),
      }),
    );
    expect(res.status).toBe(401);
  });

  it("rejects a non-JSON body as 400", async () => {
    const adminSecret = requireEnv("KOOM_ADMIN_SECRET");
    const res = await diffPOST(
      new Request("http://localhost/api/admin/uploads/diff", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${adminSecret}`,
        },
        body: "not json at all",
      }),
    );
    expect(res.status).toBe(400);
  });

  it("rejects a body missing the filenames field as 400", async () => {
    const res = await callDiff({});
    expect(res.status).toBe(400);
  });

  it("rejects a filenames field that is not an array as 400", async () => {
    const res = await callDiff({ filenames: "not an array" });
    expect(res.status).toBe(400);
  });

  it("rejects a filenames array containing non-strings as 400", async () => {
    const res = await callDiff({ filenames: ["valid.mp4", 42, null] });
    expect(res.status).toBe(400);
  });
});

// ────────────────────────────────────────────────────────────────────
// Catch-up simulation (end-to-end against real R2)
// ────────────────────────────────────────────────────────────────────

describe("catch-up simulation (client behavior without Swift)", () => {
  it("uploads one file via init/PUT/complete, inserts another directly, and diffs correctly", async () => {
    const adminSecret = requireEnv("KOOM_ADMIN_SECRET");
    const r2Bucket = requireEnv("R2_BUCKET");
    const databaseUrl = requireEnv("DATABASE_URL");

    const mp4Bytes = await readFile(FIXTURE_PATH);
    const suffix = Date.now();

    // Three filenames:
    //   A: uploaded via the real init/PUT/complete flow (fresh)
    //   B: inserted directly as 'complete' (simulates a prior upload)
    //   C: never uploaded (should show up as missing)
    const filenameA = `koom_catchup_${suffix}_a.mp4`;
    const filenameB = `koom_catchup_${suffix}_b.mp4`;
    const filenameC = `koom_catchup_${suffix}_c.mp4`;

    let uploadedRecordingId: string | null = null;
    const directlyInsertedIds: string[] = [];

    try {
      // --- Path A: real upload flow for filenameA ---
      const initRes = await initPOST(
        buildAdminRequest(
          "http://localhost/api/admin/uploads/init",
          adminSecret,
          {
            originalFilename: filenameA,
            contentType: "video/mp4",
            sizeBytes: mp4Bytes.byteLength,
            durationSeconds: 1.0,
            title: null,
          },
        ),
      );
      expect(initRes.status).toBe(200);
      const initBody = (await initRes.json()) as {
        recordingId: string;
        upload: {
          strategy: string;
          method: string;
          url: string;
          headers?: Record<string, string>;
        };
      };
      uploadedRecordingId = initBody.recordingId;

      const putRes = await fetch(initBody.upload.url, {
        method: initBody.upload.method,
        headers: initBody.upload.headers,
        body: mp4Bytes,
      });
      expect(putRes.status).toBe(200);

      const completeRes = await completePOST(
        buildAdminRequest(
          "http://localhost/api/admin/uploads/complete",
          adminSecret,
          { recordingId: initBody.recordingId },
        ),
      );
      expect(completeRes.status).toBe(200);

      // --- Path B: direct DB insert for filenameB ---
      const bId = randomUUID();
      await insertRecording({
        id: bId,
        status: "complete",
        originalFilename: filenameB,
      });
      directlyInsertedIds.push(bId);

      // --- Diff: ask about all three ---
      const diffRes = await callDiff({
        filenames: [filenameA, filenameB, filenameC],
      });
      expect(diffRes.status).toBe(200);
      const diffBody = (await diffRes.json()) as {
        uploaded: string[];
        missing: string[];
      };

      expect(diffBody.uploaded.sort()).toEqual([filenameA, filenameB].sort());
      expect(diffBody.missing).toEqual([filenameC]);

      // --- Sanity: the R2 object for filenameA actually exists ---
      const s3 = makeS3Client();
      const head = await s3.send(
        new HeadObjectCommand({
          Bucket: r2Bucket,
          Key: `recordings/${initBody.recordingId}/video.mp4`,
        }),
      );
      expect(head.ContentLength).toBe(mp4Bytes.byteLength);
    } finally {
      if (uploadedRecordingId) {
        // Clean R2 object for the uploaded one.
        try {
          const s3 = makeS3Client();
          await s3.send(
            new DeleteObjectCommand({
              Bucket: r2Bucket,
              Key: `recordings/${uploadedRecordingId}/video.mp4`,
            }),
          );
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          console.warn(`[cleanup] R2 delete failed: ${msg}`);
        }
        directlyInsertedIds.push(uploadedRecordingId);
      }
      if (directlyInsertedIds.length > 0) {
        await deleteRecordingsByIds(directlyInsertedIds, databaseUrl);
      }
    }
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

function buildAdminRequest(
  url: string,
  adminSecret: string,
  body: unknown,
): Request {
  return new Request(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${adminSecret}`,
    },
    body: JSON.stringify(body),
  });
}

async function callDiff(body: unknown): Promise<Response> {
  const adminSecret = requireEnv("KOOM_ADMIN_SECRET");
  return diffPOST(
    buildAdminRequest(
      "http://localhost/api/admin/uploads/diff",
      adminSecret,
      body,
    ),
  );
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

interface InsertRecordingOpts {
  id: string;
  status: "pending" | "complete";
  originalFilename?: string;
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
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
      [
        opts.id,
        opts.status,
        null,
        opts.originalFilename ?? "test.mp4",
        null,
        1024,
        "video/mp4",
        r2Bucket,
        `recordings/${opts.id}/video.mp4`,
      ],
    );
  } finally {
    await client.end();
  }
}

async function deleteRecordingsByIds(
  ids: string[],
  databaseUrlOverride?: string,
): Promise<void> {
  const databaseUrl = databaseUrlOverride ?? requireEnv("DATABASE_URL");
  const client = new PgClient({ connectionString: databaseUrl });
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
