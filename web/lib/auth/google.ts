/**
 * Google sign-in (OpenID Connect authorization code flow with PKCE).
 *
 * The flow, end to end:
 *
 *   1. /api/auth/google/start generates a `state`, a `nonce`, and a
 *      PKCE verifier, stores them in a short-lived sealed cookie, and
 *      redirects the browser to Google's consent screen.
 *   2. Google redirects back to /api/auth/google/callback with a
 *      one-time `code`. The callback checks `state` against the
 *      cookie, then exchanges the code (plus client secret and PKCE
 *      verifier) for an ID token at Google's token endpoint.
 *   3. The ID token's claims are validated here, and the verified
 *      email must be on the KOOM_ADMIN_EMAILS allowlist.
 *
 * The ID token arrives directly from Google's token endpoint over
 * TLS in response to our own authenticated request, so per OpenID
 * Connect Core §3.1.3.7 its signature does not need to be checked
 * separately; the claims (issuer, audience, expiry, nonce, verified
 * email) still are. That keeps the flow free of JWKS fetching and
 * extra dependencies.
 */

import { createHash, randomBytes } from "node:crypto";

import { publicBaseUrl } from "./config";

const AUTHORIZATION_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];

export interface GoogleOAuthConfig {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
}

export function googleOAuthConfig(): GoogleOAuthConfig {
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    throw new Error("GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET must be set");
  }
  return {
    clientId,
    clientSecret,
    redirectUri: `${publicBaseUrl()}/api/auth/google/callback`,
  };
}

/** URL-safe random string with `bytes` bytes of entropy. */
export function randomToken(bytes = 32): string {
  return randomBytes(bytes).toString("base64url");
}

export function pkceChallenge(verifier: string): string {
  return createHash("sha256").update(verifier).digest("base64url");
}

export function buildAuthorizationUrl(
  config: GoogleOAuthConfig,
  params: { state: string; nonce: string; codeVerifier: string },
): string {
  const url = new URL(AUTHORIZATION_ENDPOINT);
  url.search = new URLSearchParams({
    client_id: config.clientId,
    redirect_uri: config.redirectUri,
    response_type: "code",
    scope: "openid email",
    state: params.state,
    nonce: params.nonce,
    code_challenge: pkceChallenge(params.codeVerifier),
    code_challenge_method: "S256",
    prompt: "select_account",
  }).toString();
  return url.toString();
}

/**
 * Exchange an authorization code for Google's ID token and return its
 * decoded claims. Throws on any non-2xx response.
 */
export async function exchangeCodeForClaims(
  config: GoogleOAuthConfig,
  code: string,
  codeVerifier: string,
): Promise<Record<string, unknown>> {
  const res = await fetch(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: config.clientId,
      client_secret: config.clientSecret,
      redirect_uri: config.redirectUri,
      grant_type: "authorization_code",
      code_verifier: codeVerifier,
    }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) {
    throw new Error(`Google token endpoint returned HTTP ${res.status}`);
  }
  const body = (await res.json()) as { id_token?: unknown };
  if (typeof body.id_token !== "string") {
    throw new Error("Google token response did not include an id_token");
  }
  return decodeJwtPayload(body.id_token);
}

export function decodeJwtPayload(jwt: string): Record<string, unknown> {
  const parts = jwt.split(".");
  if (parts.length !== 3) throw new Error("malformed ID token");
  const payload = JSON.parse(
    Buffer.from(parts[1]!, "base64url").toString("utf-8"),
  ) as unknown;
  if (typeof payload !== "object" || payload === null) {
    throw new Error("malformed ID token payload");
  }
  return payload as Record<string, unknown>;
}

export type ClaimsResult =
  | { ok: true; email: string }
  | { ok: false; reason: string };

/**
 * Validate the ID token claims we rely on. Pure, so it is unit
 * tested directly. Allowlist membership is checked separately by the
 * caller, because a valid Google identity that isn't allowlisted is a
 * different outcome ("not allowed") from a bad token ("failed").
 */
export function validateIdTokenClaims(
  claims: Record<string, unknown>,
  expected: { clientId: string; nonce: string; nowSeconds: number },
): ClaimsResult {
  if (typeof claims.iss !== "string" || !GOOGLE_ISSUERS.includes(claims.iss)) {
    return { ok: false, reason: "unexpected issuer" };
  }
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(expected.clientId)) {
    return { ok: false, reason: "token was issued for a different client" };
  }
  if (typeof claims.exp !== "number" || claims.exp <= expected.nowSeconds) {
    return { ok: false, reason: "token expired" };
  }
  if (claims.nonce !== expected.nonce) {
    return { ok: false, reason: "nonce mismatch" };
  }
  if (typeof claims.email !== "string" || claims.email.length === 0) {
    return { ok: false, reason: "token has no email" };
  }
  if (claims.email_verified !== true) {
    return { ok: false, reason: "email is not verified" };
  }
  return { ok: true, email: claims.email.toLowerCase() };
}

/**
 * Only allow redirects back to a path on this site after sign-in, so
 * `?next=` can't be abused as an open redirect.
 */
export function safeNextPath(next: string | null | undefined): string {
  if (!next || !next.startsWith("/") || next.startsWith("//")) return "/";
  if (next.includes("\\")) return "/";
  return next;
}
