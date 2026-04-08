/**
 * Seed and cleanup helpers for the E2E test.
 *
 * For each fixture MP4 produced by `generateFixtures()`, this
 * helper:
 *
 *   1. Generates a random recordingId.
 *   2. Uploads the file to the test R2 bucket under
 *      `recordings/{id}/video.mp4` so the watch page and the
 *      first-frame previews on the recordings list have real
 *      bytes to fetch.
 *   3. Inserts a corresponding `complete` row into the
 *      recordings table with the original filename and the real
 *      file size.
 *
 * `cleanupSeeded` reverses both steps. It's safe to call from a
 * test's `finally` block — DB row deletes and S3 deletes are both
 * idempotent, and any failures are logged as warnings rather than
 * thrown so test failures don't get masked by cleanup errors.
 *
 * The test environment variables (DATABASE_URL, R2_*,
 * KOOM_ADMIN_SECRET) are populated by playwright.config.ts via
 * dotenv at config import time, so they're already in process.env
 * when these helpers run.
 */

import {
  DeleteObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";

import pg from "pg";

import type { FixtureSpec } from "./fixtures";

const { Client: PgClient } = pg;

export interface SeededRecording {
  recordingId: string;
  originalFilename: string;
  sizeBytes: number;
  durationSeconds: number;
  objectKey: string;
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(
      `E2E test environment missing ${name}. Ensure web/.env.test.local is populated and Playwright loaded it via dotenv.`,
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

export async function seedRecordings(
  fixtures: FixtureSpec[],
): Promise<SeededRecording[]> {
  const databaseUrl = requireEnv("DATABASE_URL");
  const bucket = requireEnv("R2_BUCKET");
  const s3 = makeS3Client();

  const seeded: SeededRecording[] = [];

  for (const fixture of fixtures) {
    const recordingId = randomUUID();
    const objectKey = `recordings/${recordingId}/video.mp4`;

    const bytes = await readFile(fixture.localPath);
    await s3.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: objectKey,
        Body: bytes,
        ContentType: "video/mp4",
      }),
    );

    const dbClient = new PgClient({ connectionString: databaseUrl });
    await dbClient.connect();
    try {
      await dbClient.query(
        `INSERT INTO recordings
           (id, status, title, original_filename, duration_seconds,
            size_bytes, content_type, bucket, object_key)
         VALUES ($1, 'complete', null, $2, $3, $4, 'video/mp4', $5, $6)`,
        [
          recordingId,
          fixture.filename,
          fixture.durationSeconds,
          fixture.sizeBytes,
          bucket,
          objectKey,
        ],
      );
    } finally {
      await dbClient.end();
    }

    seeded.push({
      recordingId,
      originalFilename: fixture.filename,
      sizeBytes: fixture.sizeBytes,
      durationSeconds: fixture.durationSeconds,
      objectKey,
    });
  }

  return seeded;
}

export async function cleanupSeeded(seeded: SeededRecording[]): Promise<void> {
  if (seeded.length === 0) return;

  const bucket = requireEnv("R2_BUCKET");
  const databaseUrl = requireEnv("DATABASE_URL");
  const s3 = makeS3Client();

  // R2 first — DeleteObject is idempotent so calling on an
  // already-deleted key is fine.
  for (const r of seeded) {
    try {
      await s3.send(
        new DeleteObjectCommand({ Bucket: bucket, Key: r.objectKey }),
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn(
        `[seed cleanup] R2 delete failed for ${r.objectKey}: ${msg}`,
      );
    }
  }

  // Then DB rows. Single batch DELETE.
  const dbClient = new PgClient({ connectionString: databaseUrl });
  await dbClient.connect();
  try {
    await dbClient.query("DELETE FROM recordings WHERE id = ANY($1)", [
      seeded.map((r) => r.recordingId),
    ]);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn(`[seed cleanup] DB delete failed: ${msg}`);
  } finally {
    await dbClient.end();
  }
}
