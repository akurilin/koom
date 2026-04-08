/**
 * iron-session wiring for the browser admin UI.
 *
 * Single-tenant koom uses one session per logged-in browser: if
 * the cookie decrypts and carries an `authenticatedAt` timestamp,
 * the browser is admin-authenticated. No user identity, no
 * multi-role support — this is deliberately minimal.
 *
 * The session password is derived from `KOOM_ADMIN_SECRET` via
 * `sha256(secret + ':session')` so operators don't have to manage
 * a second env var. Rotating `KOOM_ADMIN_SECRET` naturally
 * invalidates every active session, which is the right behavior
 * for "my admin secret leaked, rotate it immediately."
 *
 * The desktop client and the existing integration tests continue
 * to authenticate with the `Authorization: Bearer` header via
 * `requireAdmin` in `./admin`. Both auth transports are accepted
 * on every admin endpoint.
 */

import { createHash } from "node:crypto";

import { getIronSession, type SessionOptions } from "iron-session";
import { cookies } from "next/headers";

const SESSION_COOKIE_NAME = "koom-admin-session";
const SESSION_MAX_AGE_SECONDS = 7 * 24 * 60 * 60;

/**
 * The only field we need in the session payload is "when was this
 * session authenticated." The presence of a non-zero value means
 * the user is authenticated; the value itself could be used for
 * future "re-auth after N hours" logic if we ever want it.
 */
export interface AdminSession {
  authenticatedAt?: number;
}

/**
 * Build the iron-session options. Throws if `KOOM_ADMIN_SECRET`
 * is not set — which can only happen if the operator deployed a
 * Next.js app without configuring it, in which case a 500 at
 * auth time is the correct failure mode.
 */
function getSessionOptions(): SessionOptions {
  const adminSecret = process.env.KOOM_ADMIN_SECRET;
  if (!adminSecret) {
    throw new Error(
      "KOOM_ADMIN_SECRET is not configured — cannot build session options.",
    );
  }

  // Deterministically derive a 64-char hex password from the admin
  // secret. iron-session requires ≥ 32 characters; 64 hex chars is
  // 256 bits of entropy, which is plenty, and the hash function
  // cleanly decouples the "user types this at login" secret from
  // the "encrypts the cookie contents" secret. Rotating the admin
  // secret automatically rotates the session password and
  // invalidates every existing session, because the cookie can no
  // longer be decrypted.
  const password = createHash("sha256")
    .update(adminSecret)
    .update(":session")
    .digest("hex");

  return {
    password,
    cookieName: SESSION_COOKIE_NAME,
    cookieOptions: {
      httpOnly: true,
      sameSite: "lax",
      secure: process.env.NODE_ENV === "production",
      maxAge: SESSION_MAX_AGE_SECONDS,
      path: "/",
    },
  };
}

/**
 * Fetch (or construct) the admin session for the current request.
 *
 * This reads the cookie store from Next.js's `cookies()` helper,
 * which is only available inside route handlers, server actions,
 * and server components — i.e. this must be called from request-
 * scoped server code. It is NOT safe to call from module-top-level
 * or from test code that directly imports route handlers; in
 * those contexts the cookie store is not available and iron-session
 * will throw.
 */
export async function getAdminSession() {
  const cookieStore = await cookies();
  return getIronSession<AdminSession>(cookieStore, getSessionOptions());
}

/**
 * Best-effort "is the current request authenticated via session
 * cookie?" check. Returns `false` on any error (including
 * "cookie store not available") so callers can fall back to
 * bearer-token auth without the whole request exploding on a
 * missing next/headers context.
 */
export async function isAdminSessionValid(): Promise<boolean> {
  try {
    const session = await getAdminSession();
    return (
      typeof session.authenticatedAt === "number" && session.authenticatedAt > 0
    );
  } catch {
    return false;
  }
}
