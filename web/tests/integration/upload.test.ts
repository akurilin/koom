/**
 * Integration test for the upload flow.
 *
 * Exercises init → presigned PUT to R2 → complete end-to-end against
 * real local Postgres and real Cloudflare R2. Simulates the desktop
 * client using the exact HTTP contract the Swift client will use:
 *
 *   1. POST /api/admin/uploads/init with JSON metadata + Bearer auth
 *   2. PUT raw MP4 bytes directly to the returned presigned URL
 *   3. POST /api/admin/uploads/complete with the recordingId
 *
 * The route handlers are imported and called directly with
 * constructed Request objects rather than going through a running
 * Next.js dev server. This is faster and simpler while still
 * exercising the real auth header check, the real pg queries against
 * local Supabase, and the real S3 calls to Cloudflare R2. The only
 * thing it does NOT cover is Next.js's HTTP framing layer, which is
 * Next.js's job to test, not ours.
 *
 * The `fetch(upload.url, ...)` call to R2 is over the real network.
 *
 * Cleanup always runs in a `finally` block regardless of test
 * outcome, deleting the R2 object and the DB row. Cleanup failures
 * are logged as warnings but do not fail the test — the test's
 * assertions have already run by the time cleanup executes.
 */

import {
  DeleteObjectCommand,
  HeadObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { describe, expect, it } from "vitest";

import { POST as completePOST } from "@/app/api/admin/uploads/complete/route";
import { POST as initPOST } from "@/app/api/admin/uploads/init/route";

const { Client: PgClient } = pg;

const thisDir = resolve(fileURLToPath(import.meta.url), "..");
const FIXTURE_PATH = resolve(thisDir, "..", "fixtures", "sample.mp4");

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

describe("POST /api/admin/uploads (init → PUT → complete)", () => {
  it("uploads a real MP4 end-to-end and marks the row complete", async () => {
    const adminSecret = requireEnv("KOOM_ADMIN_SECRET");
    const r2Bucket = requireEnv("R2_BUCKET");
    const databaseUrl = requireEnv("DATABASE_URL");

    const mp4Bytes = await readFile(FIXTURE_PATH);
    expect(mp4Bytes.byteLength).toBeGreaterThan(0);

    let recordingId: string | null = null;

    try {
      // ── Step 1: init ─────────────────────────────────────────────
      const initReq = new Request("http://localhost/api/admin/uploads/init", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${adminSecret}`,
        },
        body: JSON.stringify({
          originalFilename: "sample.mp4",
          contentType: "video/mp4",
          sizeBytes: mp4Bytes.byteLength,
          durationSeconds: 1.0,
          title: null,
        }),
      });

      const initRes = await initPOST(initReq);
      expect(initRes.status).toBe(200);

      const initBody = (await initRes.json()) as {
        recordingId: string;
        upload: {
          strategy: string;
          method: string;
          url: string;
          headers?: Record<string, string>;
        };
        shareUrl: string;
      };

      expect(initBody.recordingId).toMatch(UUID_REGEX);
      recordingId = initBody.recordingId;

      expect(initBody.upload.strategy).toBe("single-put");
      expect(initBody.upload.method).toBe("PUT");
      expect(initBody.upload.url).toMatch(/^https:\/\//);
      expect(initBody.shareUrl).toContain(initBody.recordingId);

      // ── Step 2: PUT bytes directly to R2 via the presigned URL ──
      const putRes = await fetch(initBody.upload.url, {
        method: initBody.upload.method,
        headers: initBody.upload.headers,
        body: mp4Bytes,
      });
      expect(putRes.status).toBe(200);

      // ── Step 3: complete ────────────────────────────────────────
      const completeReq = new Request(
        "http://localhost/api/admin/uploads/complete",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${adminSecret}`,
          },
          body: JSON.stringify({ recordingId: initBody.recordingId }),
        },
      );

      const completeRes = await completePOST(completeReq);
      expect(completeRes.status).toBe(200);

      const completeBody = (await completeRes.json()) as {
        recordingId: string;
        shareUrl: string;
      };
      expect(completeBody.recordingId).toBe(initBody.recordingId);
      expect(completeBody.shareUrl).toBe(initBody.shareUrl);

      // ── Assert: DB row is in the expected final state ───────────
      const dbRow = await selectRecording(databaseUrl, initBody.recordingId);
      expect(dbRow).not.toBeNull();
      expect(dbRow!.status).toBe("complete");
      // BIGINT comes back from pg as a string to preserve precision.
      expect(dbRow!.size_bytes).toBe(String(mp4Bytes.byteLength));
      expect(dbRow!.original_filename).toBe("sample.mp4");
      expect(dbRow!.content_type).toBe("video/mp4");
      expect(dbRow!.bucket).toBe(r2Bucket);
      expect(dbRow!.object_key).toBe(
        `recordings/${initBody.recordingId}/video.mp4`,
      );

      // ── Assert: R2 object exists with matching size ─────────────
      const s3 = makeS3Client();
      const head = await s3.send(
        new HeadObjectCommand({
          Bucket: r2Bucket,
          Key: `recordings/${initBody.recordingId}/video.mp4`,
        }),
      );
      expect(head.ContentLength).toBe(mp4Bytes.byteLength);
    } finally {
      // Always attempt to clean up the R2 object and the DB row,
      // regardless of whether the test passed or failed. Warnings
      // go to stderr but never fail the test — the meaningful
      // assertions already ran above.
      if (recordingId) {
        await cleanup(recordingId, r2Bucket, databaseUrl);
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

interface RecordingRow {
  status: string;
  size_bytes: string;
  original_filename: string;
  content_type: string;
  bucket: string;
  object_key: string;
}

async function selectRecording(
  databaseUrl: string,
  recordingId: string,
): Promise<RecordingRow | null> {
  const client = new PgClient({ connectionString: databaseUrl });
  await client.connect();
  try {
    const { rows } = await client.query<RecordingRow>(
      `SELECT status, size_bytes, original_filename,
              content_type, bucket, object_key
         FROM recordings
        WHERE id = $1`,
      [recordingId],
    );
    return rows[0] ?? null;
  } finally {
    await client.end();
  }
}

async function cleanup(
  recordingId: string,
  bucket: string,
  databaseUrl: string,
): Promise<void> {
  // Delete R2 object (best effort)
  try {
    const s3 = makeS3Client();
    await s3.send(
      new DeleteObjectCommand({
        Bucket: bucket,
        Key: `recordings/${recordingId}/video.mp4`,
      }),
    );
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn(
      `[cleanup] R2 delete failed for recordings/${recordingId}/video.mp4: ${msg}`,
    );
  }

  // Delete DB row (best effort)
  try {
    const client = new PgClient({ connectionString: databaseUrl });
    await client.connect();
    try {
      await client.query("DELETE FROM recordings WHERE id = $1", [recordingId]);
    } finally {
      await client.end();
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn(`[cleanup] DB delete failed for ${recordingId}: ${msg}`);
  }
}
