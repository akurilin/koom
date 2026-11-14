import { createHash } from "node:crypto";

import { describe, expect, it } from "vitest";

import {
  buildAuthorizationUrl,
  decodeJwtPayload,
  safeNextPath,
  validateIdTokenClaims,
} from "@/lib/auth/google";

const CLIENT_ID = "client-123.apps.googleusercontent.com";
const NOW = 1_800_000_000;

function claims(overrides: Record<string, unknown> = {}) {
  return {
    iss: "https://accounts.google.com",
    aud: CLIENT_ID,
    exp: NOW + 300,
    nonce: "nonce-abc",
    email: "Admin@Example.com",
    email_verified: true,
    ...overrides,
  };
}

const expected = { clientId: CLIENT_ID, nonce: "nonce-abc", nowSeconds: NOW };

describe("validateIdTokenClaims", () => {
  it("accepts a valid token and lowercases the email", () => {
    expect(validateIdTokenClaims(claims(), expected)).toEqual({
      ok: true,
      email: "admin@example.com",
    });
  });

  it("accepts the bare accounts.google.com issuer and array audiences", () => {
    const result = validateIdTokenClaims(
      claims({ iss: "accounts.google.com", aud: ["other", CLIENT_ID] }),
      expected,
    );
    expect(result.ok).toBe(true);
  });

  it.each([
    ["a foreign issuer", { iss: "https://evil.example.com" }],
    ["another client's audience", { aud: "someone-else" }],
    ["an expired token", { exp: NOW }],
    ["a mismatched nonce", { nonce: "replayed" }],
    ["a missing email", { email: undefined }],
    ["an unverified email", { email_verified: false }],
    ["a string email_verified", { email_verified: "true" }],
  ])("rejects %s", (_label, overrides) => {
    expect(validateIdTokenClaims(claims(overrides), expected).ok).toBe(false);
  });
});

describe("decodeJwtPayload", () => {
  it("decodes the middle segment", () => {
    const payload = Buffer.from(JSON.stringify({ sub: "1" })).toString(
      "base64url",
    );
    expect(decodeJwtPayload(`header.${payload}.sig`)).toEqual({ sub: "1" });
  });

  it("rejects malformed tokens", () => {
    expect(() => decodeJwtPayload("not-a-jwt")).toThrow();
  });
});

describe("safeNextPath", () => {
  it.each([
    ["/", "/"],
    ["/r/abc?t=10", "/r/abc?t=10"],
    ["/connect?state=x&device=y", "/connect?state=x&device=y"],
    [null, "/"],
    ["", "/"],
    ["https://evil.example.com", "/"],
    ["//evil.example.com", "/"],
    ["/\\evil.example.com", "/"],
    ["javascript:alert(1)", "/"],
  ])("%s → %s", (input, output) => {
    expect(safeNextPath(input)).toBe(output);
  });
});

describe("buildAuthorizationUrl", () => {
  it("sends an S256 PKCE challenge derived from the verifier", () => {
    const url = new URL(
      buildAuthorizationUrl(
        {
          clientId: CLIENT_ID,
          clientSecret: "unused",
          redirectUri: "https://koom.example.com/api/auth/google/callback",
        },
        { state: "s", nonce: "n", codeVerifier: "verifier" },
      ),
    );
    const challenge = createHash("sha256")
      .update("verifier")
      .digest("base64url");
    expect(url.searchParams.get("code_challenge")).toBe(challenge);
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
    expect(url.searchParams.get("redirect_uri")).toBe(
      "https://koom.example.com/api/auth/google/callback",
    );
    // The verifier itself must never leave the server.
    expect(url.toString()).not.toContain("verifier");
  });
});
