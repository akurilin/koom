/**
 * POST /api/admin/device-tokens — mint a token for the desktop app.
 *
 * Submitted by the confirmation form on /connect, which the desktop
 * app opens in an ASWebAuthenticationSession. Requires the browser
 * admin session (a device token cannot mint more tokens). Responds
 * with a 303 to koom://auth-callback carrying the new token, which
 * completes the desktop app's sign-in.
 *
 * The session cookie is SameSite=Lax, so a cross-site form post
 * arrives without it and is rejected.
 */

import {
  desktopCallbackUrl,
  isValidDeviceState,
  mintDeviceToken,
  normalizeDeviceLabel,
} from "@/lib/auth/device-tokens";
import { currentAdminEmail } from "@/lib/auth/session";
import { jsonError } from "@/lib/http";

export async function POST(request: Request): Promise<Response> {
  const email = await currentAdminEmail();
  if (!email) return jsonError(401, "unauthorized");

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return jsonError(400, "expected a form submission");
  }
  const state = form.get("state");
  if (typeof state !== "string" || !isValidDeviceState(state)) {
    return jsonError(400, "invalid state");
  }
  const device = form.get("device");
  const label = normalizeDeviceLabel(
    typeof device === "string" ? device : null,
  );

  const { token } = await mintDeviceToken({ email, label });

  return new Response(null, {
    status: 303,
    headers: {
      Location: desktopCallbackUrl({ state, token, email }),
      "Cache-Control": "no-store",
    },
  });
}
