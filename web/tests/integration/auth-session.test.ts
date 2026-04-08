/**
 * Integration test for the session-creation surface:
 *   POST /api/admin/session
 *
 * Scope of this file is intentionally limited: we verify the
 * validation and error paths that can be exercised by calling
 * the route handler directly with a constructed Request. That
 * covers:
 *
 *   - wrong secret  -> 401
 *   - missing field -> 400
 *   - wrong types   -> 400
 *   - invalid JSON  -> 400
 *
 * We deliberately do NOT test the happy path (correct secret ->
 * 200 + session cookie set) here. iron-session's cookie write is
 * routed through Next.js's `cookies()` helper, which only works
 * inside a real request context. Invoking the handler directly
 * from vitest is not a real request context, so `session.save()`
 * either throws or silently no-ops. The full cookie round-trip
 * (POST session -> cookie set -> cookie sent on next request ->
 * cookie cleared on DELETE) is verified end-to-end by the
 * Playwright E2E test in round D-3, which runs against a real
 * Next.js server.
 *
 * The bearer-auth side of requireAdmin continues to be exercised
 * by all the other admin-route tests (upload / diff / recordings
 * list / recordings delete).
 */

import { describe, expect, it } from "vitest";

import { POST as sessionPOST } from "@/app/api/admin/session/route";

function buildJSONRequest(body: unknown): Request {
  return new Request("http://localhost/api/admin/session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function buildRawBodyRequest(rawBody: string): Request {
  return new Request("http://localhost/api/admin/session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: rawBody,
  });
}

describe("POST /api/admin/session (validation errors)", () => {
  it("returns 401 when the secret is wrong", async () => {
    const res = await sessionPOST(
      buildJSONRequest({ secret: "definitely-not-the-right-secret" }),
    );
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body).toEqual({ error: "invalid secret" });
  });

  it("returns 400 when the secret field is missing", async () => {
    const res = await sessionPOST(buildJSONRequest({}));
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/secret/);
  });

  it("returns 400 when the secret field is not a string", async () => {
    const res = await sessionPOST(buildJSONRequest({ secret: 12345 }));
    expect(res.status).toBe(400);
  });

  it("returns 400 when the secret field is an empty string", async () => {
    const res = await sessionPOST(buildJSONRequest({ secret: "" }));
    expect(res.status).toBe(400);
  });

  it("returns 400 when the body is not valid JSON", async () => {
    const res = await sessionPOST(buildRawBodyRequest("not json at all"));
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/JSON/);
  });
});
