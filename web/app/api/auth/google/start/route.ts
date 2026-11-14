/**
 * GET /api/auth/google/start?next=/path
 *
 * Begins Google sign-in: stores fresh state, nonce, and PKCE verifier
 * in the short-lived koom-oauth cookie, then redirects to Google.
 * `next` is where the callback sends the browser after a successful
 * sign-in (restricted to paths on this site).
 */

import {
  buildAuthorizationUrl,
  googleOAuthConfig,
  randomToken,
  safeNextPath,
} from "@/lib/auth/google";
import { getOAuthFlowSession } from "@/lib/auth/session";

export async function GET(request: Request): Promise<Response> {
  const config = googleOAuthConfig();
  const next = safeNextPath(new URL(request.url).searchParams.get("next"));

  const flow = await getOAuthFlowSession();
  flow.state = randomToken();
  flow.nonce = randomToken();
  flow.codeVerifier = randomToken();
  flow.next = next;
  await flow.save();

  return new Response(null, {
    status: 303,
    headers: {
      Location: buildAuthorizationUrl(config, {
        state: flow.state,
        nonce: flow.nonce,
        codeVerifier: flow.codeVerifier,
      }),
      "Cache-Control": "no-store",
    },
  });
}
