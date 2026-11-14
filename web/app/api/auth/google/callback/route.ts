/**
 * GET /api/auth/google/callback?code=...&state=...
 *
 * Completes Google sign-in. On success, stores the verified email in
 * the admin session cookie and redirects to the `next` path saved by
 * /api/auth/google/start. Every failure lands on /login with an
 * `error` code the page turns into a message:
 *
 *   not_allowed  valid Google account, but not on KOOM_ADMIN_EMAILS
 *   failed       anything else (cancelled consent, stale or forged
 *                state, token exchange or claim validation failure)
 */

import { isAllowedAdminEmail, publicBaseUrl } from "@/lib/auth/config";
import {
  exchangeCodeForClaims,
  googleOAuthConfig,
  validateIdTokenClaims,
} from "@/lib/auth/google";
import { getAdminSession, getOAuthFlowSession } from "@/lib/auth/session";

function redirectTo(path: string): Response {
  return new Response(null, {
    status: 303,
    headers: {
      Location: `${publicBaseUrl()}${path}`,
      "Cache-Control": "no-store",
    },
  });
}

export async function GET(request: Request): Promise<Response> {
  const params = new URL(request.url).searchParams;
  const flow = await getOAuthFlowSession();
  const { state, nonce, codeVerifier, next } = flow;
  // One-shot: the flow cookie is spent whether or not this succeeds.
  flow.destroy();

  const code = params.get("code");
  if (
    !code ||
    !state ||
    !nonce ||
    !codeVerifier ||
    params.get("state") !== state
  ) {
    return redirectTo("/login?error=failed");
  }

  const config = googleOAuthConfig();
  let email: string;
  try {
    const claims = await exchangeCodeForClaims(config, code, codeVerifier);
    const result = validateIdTokenClaims(claims, {
      clientId: config.clientId,
      nonce,
      nowSeconds: Math.floor(Date.now() / 1000),
    });
    if (!result.ok) {
      console.warn(`[auth] Google sign-in rejected: ${result.reason}`);
      return redirectTo("/login?error=failed");
    }
    email = result.email;
  } catch (err) {
    console.error("[auth] Google sign-in failed:", err);
    return redirectTo("/login?error=failed");
  }

  if (!isAllowedAdminEmail(email)) {
    console.warn(`[auth] Google sign-in by non-admin account ${email}`);
    return redirectTo("/login?error=not_allowed");
  }

  const session = await getAdminSession();
  session.email = email;
  session.authenticatedAt = Date.now();
  await session.save();

  return redirectTo(next ?? "/");
}
