/**
 * Admin authentication for API routes.
 *
 * V1 uses a single deployment-wide shared secret (KOOM_ADMIN_SECRET)
 * as the only credential. Two transports are planned:
 *
 *   1. Authorization: Bearer <secret>  (used by the desktop client)
 *   2. Signed session cookie            (for the browser admin UI)
 *
 * Only the bearer-header path is implemented in this round because
 * the upload flow only needs that. Cookie sessions land in a later
 * round alongside the /app/login page.
 */

import { timingSafeEqual } from "node:crypto";

/**
 * Check the Authorization: Bearer header against KOOM_ADMIN_SECRET.
 *
 * Returns `null` on success. On failure, returns a ready-to-return
 * Response the route handler can propagate directly:
 *
 *   const authError = requireAdminBearer(request);
 *   if (authError) return authError;
 *
 * Uses constant-time comparison to avoid leaking information about
 * the secret through timing side-channels. The attack surface on a
 * single-tenant shared-secret setup is tiny, but doing the right
 * thing costs nothing.
 */
export function requireAdminBearer(request: Request): Response | null {
  const expected = process.env.KOOM_ADMIN_SECRET;
  if (!expected) {
    return Response.json(
      { error: "KOOM_ADMIN_SECRET not configured on the server" },
      { status: 500 },
    );
  }

  const header = request.headers.get("authorization");
  if (!header || !header.toLowerCase().startsWith("bearer ")) {
    return unauthorized();
  }

  const provided = header.slice("bearer ".length).trim();
  if (!provided || !constantTimeEqual(provided, expected)) {
    return unauthorized();
  }

  return null;
}

function unauthorized(): Response {
  return Response.json({ error: "unauthorized" }, { status: 401 });
}

function constantTimeEqual(a: string, b: string): boolean {
  const aBuf = Buffer.from(a, "utf-8");
  const bBuf = Buffer.from(b, "utf-8");
  // timingSafeEqual requires equal lengths; bail out early if they
  // differ but do it in a way that still reveals nothing beyond the
  // fact the lengths differ.
  if (aBuf.length !== bBuf.length) return false;
  return timingSafeEqual(aBuf, bBuf);
}
