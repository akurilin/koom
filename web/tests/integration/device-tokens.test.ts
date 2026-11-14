/**
 * Device token lifecycle against the real local Postgres: minting,
 * bearer authentication through requireAdmin, revocation via
 * DELETE /api/admin/device-tokens/current, and revocation by removing
 * the minting email from KOOM_ADMIN_EMAILS.
 *
 * The browser half (Google sign-in, the /connect confirmation, and
 * the cookie-authenticated POST that mints a token) needs a real
 * request context and Google, so it is covered by hand; here we only
 * check that the mint endpoint refuses requests without a session.
 */

import { afterAll, afterEach, describe, expect, it } from "vitest";

import { POST as mintPOST } from "@/app/api/admin/device-tokens/route";
import { DELETE as revokeCurrentDELETE } from "@/app/api/admin/device-tokens/current/route";
import { requireAdmin } from "@/lib/auth/admin";
import {
  authenticateDeviceToken,
  mintDeviceToken,
} from "@/lib/auth/device-tokens";
import { getDb } from "@/lib/db/client";

const LABEL = "integration-test-device";
const originalAllowlist = process.env.KOOM_ADMIN_EMAILS;
const adminEmail = originalAllowlist!.split(",")[0]!.trim();

function withBearer(token: string, method = "GET"): Request {
  return new Request("http://localhost/api/admin/recordings", {
    method,
    headers: { Authorization: `Bearer ${token}` },
  });
}

afterEach(() => {
  process.env.KOOM_ADMIN_EMAILS = originalAllowlist;
});

afterAll(async () => {
  await getDb().query("DELETE FROM device_tokens WHERE label = $1", [LABEL]);
});

describe("device tokens", () => {
  it("authenticates a freshly minted token and records its use", async () => {
    const { id, token } = await mintDeviceToken({
      email: adminEmail,
      label: LABEL,
    });

    expect(await requireAdmin(withBearer(token))).toBeNull();

    const { rows } = await getDb().query<{ last_used_at: Date | null }>(
      "SELECT last_used_at FROM device_tokens WHERE id = $1",
      [id],
    );
    expect(rows[0]?.last_used_at).not.toBeNull();
  });

  it("stores only a hash, never the token itself", async () => {
    const { id, token } = await mintDeviceToken({
      email: adminEmail,
      label: LABEL,
    });
    const { rows } = await getDb().query<{ token_hash: string }>(
      "SELECT token_hash FROM device_tokens WHERE id = $1",
      [id],
    );
    expect(rows[0]?.token_hash).not.toContain(token);
    expect(rows[0]?.token_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("rejects unknown and malformed tokens", async () => {
    const unknown = await requireAdmin(withBearer("koom_dt_not-a-real-token"));
    expect(unknown?.status).toBe(401);
    const malformed = await requireAdmin(withBearer("some-old-admin-secret"));
    expect(malformed?.status).toBe(401);
  });

  it("stops accepting a token once its email leaves the allowlist", async () => {
    const { token } = await mintDeviceToken({
      email: adminEmail,
      label: LABEL,
    });
    process.env.KOOM_ADMIN_EMAILS = "someone-else@example.com";
    expect(await authenticateDeviceToken(token)).toBeNull();

    process.env.KOOM_ADMIN_EMAILS = originalAllowlist;
    expect(await authenticateDeviceToken(token)).not.toBeNull();
  });

  it("revokes the presenting token on DELETE /current", async () => {
    const { token } = await mintDeviceToken({
      email: adminEmail,
      label: LABEL,
    });

    const res = await revokeCurrentDELETE(withBearer(token, "DELETE"));
    expect(res.status).toBe(200);
    expect(await requireAdmin(withBearer(token))).not.toBeNull();

    const again = await revokeCurrentDELETE(withBearer(token, "DELETE"));
    expect(again.status).toBe(401);
  });

  it("refuses to mint a token without a browser session, even with a valid bearer", async () => {
    const { token } = await mintDeviceToken({
      email: adminEmail,
      label: LABEL,
    });
    const form = new FormData();
    form.set("state", "abcdefghijklmnopqrstuvwx");
    form.set("device", "attacker");
    const res = await mintPOST(
      new Request("http://localhost/api/admin/device-tokens", {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
        body: form,
      }),
    );
    expect(res.status).toBe(401);
  });
});
