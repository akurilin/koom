/**
 * DELETE /api/admin/device-tokens/current — revoke the presenting
 * device token. Called by the desktop app when the user signs out.
 */

import {
  authenticateDeviceToken,
  bearerToken,
  revokeDeviceToken,
} from "@/lib/auth/device-tokens";
import { jsonError } from "@/lib/http";

export async function DELETE(request: Request): Promise<Response> {
  const token = bearerToken(request);
  const device = token ? await authenticateDeviceToken(token) : null;
  if (!device) return jsonError(401, "unauthorized");

  await revokeDeviceToken(device.id);
  return Response.json({ ok: true });
}
