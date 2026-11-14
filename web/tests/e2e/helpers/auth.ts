/**
 * Admin sign-in for E2E tests.
 *
 * Real sign-in goes through Google, which tests can't drive. Instead
 * we seal the same iron-session payload the Google callback writes
 * (`{ email, authenticatedAt }`) with the test KOOM_SESSION_SECRET
 * and install it as the koom-admin-session cookie. The server then
 * treats the browser exactly as if Google sign-in had succeeded for
 * the first KOOM_ADMIN_EMAILS address.
 */

import type { Page } from "@playwright/test";
import { sealData } from "iron-session";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(
      `${name} is not set in the Playwright environment. Check web/.env.test.local.`,
    );
  }
  return value;
}

export async function signInAsAdmin(
  page: Page,
  baseURL: string,
): Promise<void> {
  const email = requireEnv("KOOM_ADMIN_EMAILS").split(",")[0]!.trim();
  const value = await sealData(
    { email, authenticatedAt: Date.now() },
    { password: requireEnv("KOOM_SESSION_SECRET"), ttl: 7 * 24 * 60 * 60 },
  );
  await page
    .context()
    .addCookies([
      { name: "koom-admin-session", value, url: baseURL, httpOnly: true },
    ]);
}
