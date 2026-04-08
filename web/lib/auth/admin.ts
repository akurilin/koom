/**
 * Admin authentication for API routes.
 *
 * V1 uses a single deployment-wide shared secret (KOOM_ADMIN_SECRET)
 * as the only credential, with two accepted transports:
 *
 *   1. Authorization: Bearer <secret>   (desktop client, tests,
 *                                        anything that prefers a
 *                                        stateless credential)
 *   2. Signed session cookie             (browser admin UI after
 *                                        logging in via /app/login)
 *
 * Both transports validate against the same `KOOM_ADMIN_SECRET`.
 * The session cookie's encryption key is derived from that same
 * secret (see ./session), so rotating the admin secret rotates
 * both transports simultaneously.
 *
 * Route handlers call `requireAdmin(request)` at the top. It
 * returns `null` if either transport is valid, or a ready-to-
 * return 401 Response that the handler can propagate directly.
 * The typical pattern:
 *
 *     const authError = await requireAdmin(request);
 *     if (authError) return authError;
 *     // ... proceed with handler logic
 */

import { timingSafeEqual } from "node:crypto";

import { isAdminSessionValid } from "./session";

/**
 * Check the incoming request against both auth transports. Returns
 * `null` if at least one transport presents a valid credential,
 * otherwise a 401 Response.
 *
 * This is async because the session path has to read the cookie
 * store from `next/headers`, which is an async API in Next.js 15+.
 */
export async function requireAdmin(request: Request): Promise<Response | null> {
  const expected = process.env.KOOM_ADMIN_SECRET;
  if (!expected) {
    return Response.json(
      { error: "KOOM_ADMIN_SECRET not configured on the server" },
      { status: 500 },
    );
  }

  // Bearer header path — cheapest check, runs synchronously.
  if (hasValidBearer(request, expected)) {
    return null;
  }

  // Session cookie path — reads cookies via next/headers.
  if (await isAdminSessionValid()) {
    return null;
  }

  return unauthorized();
}

function hasValidBearer(request: Request, expected: string): boolean {
  const header = request.headers.get("authorization");
  if (!header || !header.toLowerCase().startsWith("bearer ")) {
    return false;
  }
  const provided = header.slice("bearer ".length).trim();
  if (!provided) return false;
  return constantTimeEqual(provided, expected);
}

function unauthorized(): Response {
  return Response.json({ error: "unauthorized" }, { status: 401 });
}

function constantTimeEqual(a: string, b: string): boolean {
  const aBuf = Buffer.from(a, "utf-8");
  const bBuf = Buffer.from(b, "utf-8");
  if (aBuf.length !== bBuf.length) return false;
  return timingSafeEqual(aBuf, bBuf);
}
