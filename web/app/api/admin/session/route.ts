/**
 * DELETE /api/admin/session — sign the browser out.
 *
 * Signing in happens through Google (/api/auth/google/start). This
 * route only clears the admin session cookie; it needs no auth, since
 * destroying an absent session is a no-op.
 */

import { getAdminSession } from "@/lib/auth/session";

export async function DELETE(): Promise<Response> {
  const session = await getAdminSession();
  session.destroy();
  return Response.json({ ok: true });
}
