/**
 * Cloudflare R2 (S3-compatible) client and helpers for koom.
 *
 * The runtime client uses R2 S3 credentials minted by
 * scripts/r2-setup.ts and stored in web/.env.local as R2_ACCESS_KEY_ID
 * and R2_SECRET_ACCESS_KEY. It never touches the Cloudflare REST API
 * or the higher-privilege setup token.
 *
 * All object key generation flows through recordingObjectKey() so
 * there's exactly one place the layout `recordings/{id}/video.mp4`
 * is defined.
 */

import {
  DeleteObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const DEFAULT_PRESIGNED_PUT_EXPIRY_SECONDS = 15 * 60;

let client: S3Client | null = null;

export function getR2Client(): S3Client {
  if (client) return client;

  const accountId = process.env.R2_ACCOUNT_ID;
  const accessKeyId = process.env.R2_ACCESS_KEY_ID;
  const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY;

  if (!accountId || !accessKeyId || !secretAccessKey) {
    throw new Error(
      "R2 credentials missing. Ensure R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, " +
        "and R2_SECRET_ACCESS_KEY are set in web/.env.local.",
    );
  }

  client = new S3Client({
    region: "auto",
    endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
    credentials: { accessKeyId, secretAccessKey },
  });
  return client;
}

function requireBucket(): string {
  const bucket = process.env.R2_BUCKET;
  if (!bucket) {
    throw new Error("R2_BUCKET not set in web/.env.local");
  }
  return bucket;
}

export function recordingObjectKey(recordingId: string): string {
  return `recordings/${recordingId}/video.mp4`;
}

export function recordingThumbnailObjectKey(recordingId: string): string {
  return `recordings/${recordingId}/thumbnail-v1.jpg`;
}

/**
 * Build the public playback URL for a recording. Served by R2's
 * managed `.r2.dev` subdomain (or a custom domain in production),
 * fronted by Cloudflare's CDN. Safe to embed in `<video src>` and
 * in JSON API responses.
 */
export function recordingPublicUrl(recordingId: string): string {
  const base = process.env.R2_PUBLIC_BASE_URL;
  if (!base) {
    throw new Error("R2_PUBLIC_BASE_URL not set");
  }
  return `${base.replace(/\/$/, "")}/${recordingObjectKey(recordingId)}`;
}

/**
 * Build the user-facing share URL for a recording (e.g. for the
 * response to the upload init/complete endpoints). Uses
 * KOOM_PUBLIC_BASE_URL, not R2_PUBLIC_BASE_URL.
 */
export function recordingShareUrl(recordingId: string): string {
  const base = process.env.KOOM_PUBLIC_BASE_URL;
  if (!base) {
    throw new Error("KOOM_PUBLIC_BASE_URL is not set");
  }
  return `${base.replace(/\/$/, "")}/r/${recordingId}`;
}

export function recordingThumbnailPublicUrl(recordingId: string): string {
  const base = process.env.R2_PUBLIC_BASE_URL;
  if (!base) {
    throw new Error("R2_PUBLIC_BASE_URL not set");
  }
  return `${base.replace(/\/$/, "")}/${recordingThumbnailObjectKey(recordingId)}`;
}

/**
 * Mint a time-limited presigned PUT URL for the desktop client to
 * upload video bytes directly to R2, bypassing the Next.js backend.
 * The default expiry is 15 minutes which comfortably covers uploading
 * a multi-GB file over a typical broadband connection.
 *
 * The returned URL is signed for the specific Content-Type, so the
 * client MUST send that exact Content-Type header when PUT'ing.
 * Route handlers surface this requirement to the client via the
 * `upload.headers` field in the init response.
 */
export async function generatePresignedPutUrl(
  recordingId: string,
  contentType: string,
  expiresInSeconds: number = DEFAULT_PRESIGNED_PUT_EXPIRY_SECONDS,
): Promise<string> {
  const command = new PutObjectCommand({
    Bucket: requireBucket(),
    Key: recordingObjectKey(recordingId),
    ContentType: contentType,
  });
  return getSignedUrl(getR2Client(), command, { expiresIn: expiresInSeconds });
}

/**
 * Look up an object's size and content type via HEAD. Returns null
 * if the object does not exist, throws on any other error.
 *
 * Used by the /complete endpoint to verify the upload actually
 * landed before flipping the row's status from pending to complete.
 */
export async function headRecordingObject(
  recordingId: string,
): Promise<{ size: number; contentType: string } | null> {
  try {
    const result = await getR2Client().send(
      new HeadObjectCommand({
        Bucket: requireBucket(),
        Key: recordingObjectKey(recordingId),
      }),
    );
    return {
      size: result.ContentLength ?? 0,
      contentType: result.ContentType ?? "application/octet-stream",
    };
  } catch (err) {
    if (isNotFoundError(err)) return null;
    throw err;
  }
}

/**
 * Delete the R2 object backing a recording. Idempotent: the S3
 * DeleteObject operation succeeds even if the object does not
 * exist, so callers don't need a pre-check. Used by the admin
 * delete endpoint; the caller is responsible for removing the
 * database row separately.
 */
export async function deleteRecordingObject(
  recordingId: string,
): Promise<void> {
  await deleteObject(recordingObjectKey(recordingId));
}

export async function putRecordingThumbnail(
  recordingId: string,
  body: Uint8Array,
): Promise<void> {
  await getR2Client().send(
    new PutObjectCommand({
      Bucket: requireBucket(),
      Key: recordingThumbnailObjectKey(recordingId),
      Body: body,
      ContentType: "image/jpeg",
      CacheControl: "public, max-age=31536000, immutable",
    }),
  );
}

export async function deleteRecordingThumbnailObject(
  recordingId: string,
): Promise<void> {
  await deleteObject(recordingThumbnailObjectKey(recordingId));
}

function isNotFoundError(err: unknown): boolean {
  if (!err || typeof err !== "object") return false;
  const e = err as {
    name?: string;
    $metadata?: { httpStatusCode?: number };
  };
  return (
    e.name === "NotFound" ||
    e.name === "NoSuchKey" ||
    e.$metadata?.httpStatusCode === 404
  );
}

async function deleteObject(key: string): Promise<void> {
  await getR2Client().send(
    new DeleteObjectCommand({
      Bucket: requireBucket(),
      Key: key,
    }),
  );
}
