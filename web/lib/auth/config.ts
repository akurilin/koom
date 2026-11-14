/**
 * Deployment-level auth configuration read from the environment.
 *
 *   KOOM_ADMIN_EMAILS     Comma-separated Google accounts allowed to
 *                         administer this koom deployment. Checked on
 *                         every request, so removing an address
 *                         immediately revokes that account's browser
 *                         sessions and desktop device tokens.
 *   KOOM_PUBLIC_BASE_URL  Public origin of the web app (falls back to
 *                         Render's injected RENDER_EXTERNAL_URL). Used
 *                         for share URLs and the Google redirect URI.
 */

export function adminEmailAllowlist(): string[] {
  return (process.env.KOOM_ADMIN_EMAILS ?? "")
    .split(",")
    .map((email) => email.trim().toLowerCase())
    .filter((email) => email.length > 0);
}

export function isAllowedAdminEmail(email: string): boolean {
  return adminEmailAllowlist().includes(email.trim().toLowerCase());
}

export function publicBaseUrl(): string {
  const base =
    process.env.KOOM_PUBLIC_BASE_URL || process.env.RENDER_EXTERNAL_URL;
  if (!base) {
    throw new Error(
      "Neither KOOM_PUBLIC_BASE_URL nor RENDER_EXTERNAL_URL is set",
    );
  }
  return base.replace(/\/$/, "");
}
