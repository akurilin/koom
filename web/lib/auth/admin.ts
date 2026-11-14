/**
 * Admin authentication for API routes. Two accepted transports:
 *
 *   1. Authorization: Bearer <device token>   desktop app (and tests),
 *                                             minted per device after a
 *                                             Google sign-in
 *   2. Signed session cookie                   browser admin UI after
 *                                             signing in with Google
 *
 * Both resolve to an email that must be on KOOM_ADMIN_EMAILS.
 *
 * Route handlers call `requireAdmin(request)` at the top. It returns
 * `null` when either transport is valid, or a ready-to-return 401:
 *
 *     const authError = await requireAdmin(request);
 *     if (authError) return authError;
 */

import { authenticateDeviceToken, bearerToken } from "./device-tokens";
import { isAdminSessionValid } from "./session";

export async function requireAdmin(request: Request): Promise<Response | null> {
  const token = bearerToken(request);
  if (token && (await authenticateDeviceToken(token))) {
    return null;
  }

  if (await isAdminSessionValid()) {
    return null;
  }

  return Response.json({ error: "unauthorized" }, { status: 401 });
}
