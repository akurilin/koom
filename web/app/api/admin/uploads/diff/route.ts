/**
 * POST /api/admin/uploads/diff
 *
 * Given a list of local filenames, returns which ones are already
 * uploaded (complete recordings in the database) and which ones are
 * missing. Used by the desktop client's catch-up feature to figure
 * out what to re-upload after a failed previous run.
 *
 *   1. Require admin auth (Authorization: Bearer <KOOM_ADMIN_SECRET>).
 *   2. Parse and validate the JSON body { filenames: string[] }.
 *   3. Dedupe and filter the input; empty strings are dropped.
 *   4. Query recordings WHERE original_filename = ANY($1) AND
 *      status = 'complete'. Pending rows do not count as uploaded —
 *      the catch-up should retry them.
 *   5. Partition the input into { uploaded, missing } and return.
 *
 * Scale note: this is an O(N) approach where N is the number of
 * local files the client submits. For single-tenant koom with
 * maybe dozens of recordings, that's fine. If koom ever grows to
 * millions of files this endpoint becomes the bottleneck and we
 * would want pagination or a smarter comparison (e.g. by a
 * monotonic upload id or timestamp cursor).
 */

import { requireAdmin } from "@/lib/auth/admin";
import { getDb } from "@/lib/db/client";

interface DiffRequestBody {
  filenames?: unknown;
}

export async function POST(request: Request): Promise<Response> {
  const authError = await requireAdmin(request);
  if (authError) return authError;

  let raw: DiffRequestBody;
  try {
    raw = (await request.json()) as DiffRequestBody;
  } catch {
    return jsonError(400, "invalid JSON body");
  }

  if (!Array.isArray(raw.filenames)) {
    return jsonError(
      400,
      "filenames is required and must be an array of strings",
    );
  }

  // Validate element-by-element so we can give a precise error and
  // then treat the array as string[] for the rest of the handler.
  const validated: string[] = [];
  for (const item of raw.filenames as unknown[]) {
    if (typeof item !== "string") {
      return jsonError(400, "filenames must be an array of strings");
    }
    validated.push(item);
  }

  // Dedupe and drop empty strings. Order of first occurrence is
  // preserved (Set preserves insertion order in modern JS), which
  // gives callers a predictable response shape when they pass a
  // deterministic list.
  const unique = Array.from(new Set(validated.filter((f) => f !== "")));

  if (unique.length === 0) {
    return Response.json({ uploaded: [], missing: [] });
  }

  let rows: { original_filename: string }[];
  try {
    const result = await getDb().query<{ original_filename: string }>(
      `SELECT DISTINCT original_filename
         FROM recordings
        WHERE original_filename = ANY($1)
          AND status = 'complete'`,
      [unique],
    );
    rows = result.rows;
  } catch (err) {
    console.error("[uploads/diff] DB query failed:", err);
    return jsonError(500, "database error");
  }

  const uploadedSet = new Set(rows.map((r) => r.original_filename));
  const uploaded: string[] = [];
  const missing: string[] = [];
  for (const filename of unique) {
    if (uploadedSet.has(filename)) {
      uploaded.push(filename);
    } else {
      missing.push(filename);
    }
  }

  return Response.json({ uploaded, missing });
}

function jsonError(status: number, message: string): Response {
  return Response.json({ error: message }, { status });
}
