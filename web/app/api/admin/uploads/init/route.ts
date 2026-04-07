/**
 * POST /api/admin/uploads/init
 *
 * Starts an upload session for the desktop client.
 *
 *   1. Require admin auth (Authorization: Bearer <KOOM_ADMIN_SECRET>).
 *   2. Parse and validate the JSON body.
 *   3. Generate a new recordingId (UUID v4).
 *   4. INSERT a row into recordings with status = 'pending'.
 *   5. Mint a presigned PUT URL for recordings/{id}/video.mp4 in R2.
 *   6. Return { recordingId, upload, shareUrl }.
 *
 * The `upload` field is shaped as a discriminated union on `strategy`
 * so we can add `multipart` later without breaking the client
 * contract. Only `single-put` exists in v1.
 */

import { randomUUID } from "node:crypto";

import { requireAdminBearer } from "@/lib/auth/admin";
import { getDb } from "@/lib/db/client";
import { generatePresignedPutUrl, recordingObjectKey } from "@/lib/r2/client";

interface InitRequestBody {
  originalFilename?: unknown;
  contentType?: unknown;
  sizeBytes?: unknown;
  durationSeconds?: unknown;
  title?: unknown;
}

interface ValidatedInit {
  originalFilename: string;
  contentType: string;
  sizeBytes: number;
  durationSeconds: number | null;
  title: string | null;
}

export async function POST(request: Request): Promise<Response> {
  const authError = requireAdminBearer(request);
  if (authError) return authError;

  let raw: InitRequestBody;
  try {
    raw = (await request.json()) as InitRequestBody;
  } catch {
    return jsonError(400, "invalid JSON body");
  }

  const validation = validateInitBody(raw);
  if ("error" in validation) {
    return jsonError(400, validation.error);
  }
  const { originalFilename, contentType, sizeBytes, durationSeconds, title } =
    validation;

  const recordingId = randomUUID();

  const bucket = process.env.R2_BUCKET;
  if (!bucket) {
    return jsonError(500, "R2_BUCKET not configured on the server");
  }
  const objectKey = recordingObjectKey(recordingId);

  // Insert the pending row first. If anything downstream fails we'll
  // try to clean this up, but at worst we end up with an orphaned
  // pending row that the documented GC job sweeps later.
  try {
    await getDb().query(
      `INSERT INTO recordings
         (id, status, title, original_filename, duration_seconds,
          size_bytes, content_type, bucket, object_key)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
      [
        recordingId,
        "pending",
        title,
        originalFilename,
        durationSeconds,
        sizeBytes,
        contentType,
        bucket,
        objectKey,
      ],
    );
  } catch (err) {
    console.error("[uploads/init] DB insert failed:", err);
    return jsonError(500, "database error");
  }

  let uploadUrl: string;
  try {
    uploadUrl = await generatePresignedPutUrl(recordingId, contentType);
  } catch (err) {
    console.error("[uploads/init] presigning failed:", err);
    // Best-effort cleanup: roll back the row we just inserted so we
    // don't leave an unreachable pending record around.
    try {
      await getDb().query(`DELETE FROM recordings WHERE id = $1`, [
        recordingId,
      ]);
    } catch (cleanupErr) {
      console.error(
        "[uploads/init] rollback after presign failure also failed:",
        cleanupErr,
      );
    }
    return jsonError(500, "failed to generate upload URL");
  }

  const shareUrl = buildShareUrl(recordingId);

  return Response.json({
    recordingId,
    upload: {
      strategy: "single-put",
      method: "PUT",
      url: uploadUrl,
      headers: { "Content-Type": contentType },
    },
    shareUrl,
  });
}

// ────────────────────────────────────────────────────────────────────
// Validation and helpers
// ────────────────────────────────────────────────────────────────────

function validateInitBody(
  body: InitRequestBody,
): ValidatedInit | { error: string } {
  if (
    typeof body.originalFilename !== "string" ||
    !body.originalFilename.trim()
  ) {
    return {
      error: "originalFilename is required and must be a non-empty string",
    };
  }
  if (typeof body.contentType !== "string" || !body.contentType.trim()) {
    return { error: "contentType is required and must be a non-empty string" };
  }
  if (
    typeof body.sizeBytes !== "number" ||
    !Number.isFinite(body.sizeBytes) ||
    body.sizeBytes <= 0
  ) {
    return { error: "sizeBytes is required and must be a positive number" };
  }

  let durationSeconds: number | null = null;
  if (body.durationSeconds !== null && body.durationSeconds !== undefined) {
    if (
      typeof body.durationSeconds !== "number" ||
      !Number.isFinite(body.durationSeconds) ||
      body.durationSeconds < 0
    ) {
      return {
        error: "durationSeconds must be a non-negative number or null",
      };
    }
    durationSeconds = body.durationSeconds;
  }

  let title: string | null = null;
  if (body.title !== null && body.title !== undefined) {
    if (typeof body.title !== "string") {
      return { error: "title must be a string or null" };
    }
    const trimmed = body.title.trim();
    title = trimmed === "" ? null : trimmed;
  }

  return {
    originalFilename: body.originalFilename.trim(),
    contentType: body.contentType.trim(),
    sizeBytes: Math.floor(body.sizeBytes),
    durationSeconds,
    title,
  };
}

function buildShareUrl(recordingId: string): string {
  const base = process.env.KOOM_PUBLIC_BASE_URL?.replace(/\/$/, "") ?? "";
  return `${base}/r/${recordingId}`;
}

function jsonError(status: number, message: string): Response {
  return Response.json({ error: message }, { status });
}
