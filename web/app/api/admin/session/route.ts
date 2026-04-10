/**
 * POST /api/admin/session          — log in (create session cookie)
 * DELETE /api/admin/session        — log out (destroy session cookie)
 *
 * The browser admin UI's login form posts here with the admin
 * secret in the JSON body. We validate with a constant-time
 * comparison against `KOOM_ADMIN_SECRET`, then call
 * `session.save()` which sets the encrypted cookie on the response.
 *
 * Note that these routes do NOT themselves require auth. POST
 * validates the credential in-band; DELETE is a safe idempotent
 * operation (destroying an already-destroyed session is a no-op).
 *
 * The desktop client never hits this route — it continues to
 * authenticate with `Authorization: Bearer` on every request.
 * This route is browser-only.
 */

import { timingSafeEqual } from "node:crypto";

import { getAdminSession } from "@/lib/auth/session";
import { jsonError } from "@/lib/http";

interface LoginRequestBody {
  secret?: unknown;
}

export async function POST(request: Request): Promise<Response> {
  let raw: LoginRequestBody;
  try {
    raw = (await request.json()) as LoginRequestBody;
  } catch {
    return jsonError(400, "invalid JSON body");
  }

  if (typeof raw.secret !== "string" || raw.secret.length === 0) {
    return jsonError(400, "secret is required and must be a non-empty string");
  }

  const expected = process.env.KOOM_ADMIN_SECRET;
  if (!expected) {
    return jsonError(500, "KOOM_ADMIN_SECRET not configured on the server");
  }

  // Constant-time compare — same treatment as the bearer auth
  // path in lib/auth/admin.ts. Length mismatch is a fast reject
  // that timingSafeEqual can't accept (it requires equal lengths).
  const providedBuf = Buffer.from(raw.secret, "utf-8");
  const expectedBuf = Buffer.from(expected, "utf-8");
  if (
    providedBuf.length !== expectedBuf.length ||
    !timingSafeEqual(providedBuf, expectedBuf)
  ) {
    return jsonError(401, "invalid secret");
  }

  // Stamp the session and persist it. iron-session's .save()
  // writes a Set-Cookie header on the current Next.js response.
  const session = await getAdminSession();
  session.authenticatedAt = Date.now();
  await session.save();

  return Response.json({ ok: true });
}

export async function DELETE(): Promise<Response> {
  // destroy() is always safe to call — if there's no current
  // session, it's a no-op; if there is, it clears the cookie.
  const session = await getAdminSession();
  session.destroy();
  return Response.json({ ok: true });
}
