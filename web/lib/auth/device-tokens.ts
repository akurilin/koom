/**
 * Per-device bearer tokens for the desktop app.
 *
 * After the admin signs in with Google and confirms on /connect, the
 * server mints a random token for that device and hands it back to
 * the desktop app, which sends it as `Authorization: Bearer <token>`.
 * Only the SHA-256 hash is stored (see the device_tokens migration).
 *
 * A token is valid only while its row exists AND the email that
 * minted it is still on the KOOM_ADMIN_EMAILS allowlist.
 */

import { createHash, randomBytes, randomUUID } from "node:crypto";

import { getDb } from "@/lib/db/client";

import { isAllowedAdminEmail } from "./config";

export const DEVICE_TOKEN_PREFIX = "koom_dt_";

export function hashDeviceToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export function generateDeviceToken(): string {
  return `${DEVICE_TOKEN_PREFIX}${randomBytes(32).toString("base64url")}`;
}

export async function mintDeviceToken(params: {
  email: string;
  label: string;
}): Promise<{ id: string; token: string }> {
  const id = randomUUID();
  const token = generateDeviceToken();
  await getDb().query(
    `INSERT INTO device_tokens (id, token_hash, email, label)
     VALUES ($1, $2, $3, $4)`,
    [id, hashDeviceToken(token), params.email.toLowerCase(), params.label],
  );
  return { id, token };
}

/**
 * Resolve a presented token to its device row, recording the use.
 * Returns null for unknown tokens and for tokens whose email has been
 * removed from the allowlist.
 */
export async function authenticateDeviceToken(
  token: string,
): Promise<{ id: string; email: string } | null> {
  if (!token.startsWith(DEVICE_TOKEN_PREFIX)) return null;
  const { rows } = await getDb().query<{ id: string; email: string }>(
    `UPDATE device_tokens
        SET last_used_at = now()
      WHERE token_hash = $1
      RETURNING id, email`,
    [hashDeviceToken(token)],
  );
  const row = rows[0];
  if (!row || !isAllowedAdminEmail(row.email)) return null;
  return row;
}

export async function revokeDeviceToken(id: string): Promise<void> {
  await getDb().query("DELETE FROM device_tokens WHERE id = $1", [id]);
}

/** Extract the bearer credential from a request, if any. */
export function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  if (!header || !header.toLowerCase().startsWith("bearer ")) return null;
  const token = header.slice("bearer ".length).trim();
  return token.length > 0 ? token : null;
}

/**
 * Normalize the device name the desktop app reports. Falls back to a
 * generic label rather than rejecting, since it's informational only.
 */
export function normalizeDeviceLabel(raw: string | null | undefined): string {
  const trimmed = (raw ?? "").trim().slice(0, 200);
  return trimmed.length > 0 ? trimmed : "koom desktop";
}

/**
 * Where the desktop app's ASWebAuthenticationSession listens. The
 * server only ever redirects to this fixed URL, never to a
 * caller-supplied one.
 */
export const DESKTOP_CALLBACK_URL = "koom://auth-callback";

/** Opaque correlation value the desktop app generates per sign-in. */
export function isValidDeviceState(state: string | null): state is string {
  return state !== null && /^[A-Za-z0-9_-]{16,128}$/.test(state);
}

export function desktopCallbackUrl(params: Record<string, string>): string {
  return `${DESKTOP_CALLBACK_URL}?${new URLSearchParams(params).toString()}`;
}
