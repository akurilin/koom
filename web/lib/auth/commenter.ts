/**
 * Cookie helpers for anonymous commenter identity.
 *
 * Anonymous viewers are identified by a `koom-commenter` HttpOnly
 * cookie containing a raw UUID. Unlike the admin session cookie
 * (iron-session, encrypted), this cookie is a plain UUID:
 *
 *   - There is no privilege boundary to protect — the UUID only
 *     gates self-delete of one's own comments.
 *   - Forging it requires guessing a 128-bit UUID that maps to an
 *     existing commenter row.
 *   - Keeping it raw avoids a second iron-session schema and makes
 *     debugging trivial (just read the cookie value).
 *
 * These functions operate on raw Request objects — no Next.js
 * cookies() context needed — so they work in both route handlers
 * and integration tests.
 */

const COOKIE_NAME = "koom-commenter";
const MAX_AGE_SECONDS = 365 * 24 * 60 * 60; // 1 year

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Extract the commenter id from the request's Cookie header.
 * Returns null if the cookie is absent or the value isn't a
 * valid UUID.
 */
export function getCommenterIdFromCookie(request: Request): string | null {
  const cookieHeader = request.headers.get("cookie");
  if (!cookieHeader) return null;

  // Simple parser: split on "; ", find the koom-commenter entry.
  // No need for a full cookie parser at this scale.
  for (const pair of cookieHeader.split("; ")) {
    const eqIndex = pair.indexOf("=");
    if (eqIndex === -1) continue;
    const name = pair.slice(0, eqIndex).trim();
    const value = pair.slice(eqIndex + 1).trim();
    if (name === COOKIE_NAME && UUID_REGEX.test(value)) {
      return value;
    }
  }

  return null;
}

/**
 * Build the Set-Cookie header value for a new commenter identity.
 */
export function setCommenterCookie(commenterId: string): string {
  return [
    `${COOKIE_NAME}=${commenterId}`,
    `Path=/`,
    `HttpOnly`,
    `SameSite=Lax`,
    `Max-Age=${MAX_AGE_SECONDS}`,
  ].join("; ");
}
