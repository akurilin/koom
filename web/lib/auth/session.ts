/**
 * iron-session wiring for the browser admin UI.
 *
 * Two sealed, HttpOnly cookies share one password:
 *
 *   koom-admin-session  Set after a successful Google sign-in. Holds
 *                       the verified email; valid only while that
 *                       email is on the KOOM_ADMIN_EMAILS allowlist.
 *   koom-oauth          Short-lived state for an in-flight Google
 *                       sign-in (state, nonce, PKCE verifier, and the
 *                       path to return to).
 *
 * The password comes from KOOM_SESSION_SECRET (at least 32
 * characters). Rotating it signs every browser out. Desktop devices
 * are unaffected: they authenticate with device tokens (./device-tokens).
 */

import { getIronSession, type SessionOptions } from "iron-session";
import { cookies } from "next/headers";

import { isAllowedAdminEmail } from "./config";

export const ADMIN_SESSION_COOKIE_NAME = "koom-admin-session";
const ADMIN_SESSION_MAX_AGE_SECONDS = 7 * 24 * 60 * 60;
const OAUTH_COOKIE_NAME = "koom-oauth";
const OAUTH_MAX_AGE_SECONDS = 10 * 60;

export interface AdminSession {
  email?: string;
  authenticatedAt?: number;
}

export interface OAuthFlowState {
  state?: string;
  nonce?: string;
  codeVerifier?: string;
  next?: string;
}

export function sessionPassword(): string {
  const secret = process.env.KOOM_SESSION_SECRET;
  if (!secret || secret.length < 32) {
    throw new Error(
      "KOOM_SESSION_SECRET must be set to at least 32 characters.",
    );
  }
  return secret;
}

function options(cookieName: string, maxAge: number): SessionOptions {
  return {
    password: sessionPassword(),
    cookieName,
    cookieOptions: {
      httpOnly: true,
      // Lax so the cookie rides along on the top-level GET redirect
      // back from Google, but never on cross-site POSTs.
      sameSite: "lax",
      secure: process.env.NODE_ENV === "production",
      maxAge,
      path: "/",
    },
  };
}

export const adminSessionOptions = () =>
  options(ADMIN_SESSION_COOKIE_NAME, ADMIN_SESSION_MAX_AGE_SECONDS);

/**
 * Must be called from request-scoped server code (route handlers,
 * server components), where `cookies()` is available.
 */
export async function getAdminSession() {
  return getIronSession<AdminSession>(await cookies(), adminSessionOptions());
}

export async function getOAuthFlowSession() {
  return getIronSession<OAuthFlowState>(
    await cookies(),
    options(OAUTH_COOKIE_NAME, OAUTH_MAX_AGE_SECONDS),
  );
}

/**
 * The signed-in admin's email, or null. Returns null on any error
 * (including "cookie store not available" when a route handler is
 * invoked directly from tests) so callers can fall back to bearer
 * auth.
 */
export async function currentAdminEmail(): Promise<string | null> {
  try {
    const session = await getAdminSession();
    if (session.email && isAllowedAdminEmail(session.email)) {
      return session.email;
    }
    return null;
  } catch {
    return null;
  }
}

export async function isAdminSessionValid(): Promise<boolean> {
  return (await currentAdminEmail()) !== null;
}
