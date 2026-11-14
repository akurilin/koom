/**
 * Admin sign-in page. Sends the browser through Google sign-in
 * (/api/auth/google/start); only accounts on KOOM_ADMIN_EMAILS get
 * in. Already-signed-in visitors are bounced to `next` (or /).
 *
 * `?error=` is set by the Google callback when a sign-in fails.
 */

import { redirect } from "next/navigation";
import type { ReactElement } from "react";

import { safeNextPath } from "@/lib/auth/google";
import { isAdminSessionValid } from "@/lib/auth/session";

export const dynamic = "force-dynamic";

const ERROR_MESSAGES: Record<string, string> = {
  not_allowed:
    "That Google account isn't allowed to administer this koom. Sign in with an account listed in KOOM_ADMIN_EMAILS.",
  failed: "Google sign-in didn't complete. Please try again.",
};

export default async function LoginPage(props: {
  searchParams: Promise<{ next?: string; error?: string }>;
}): Promise<ReactElement> {
  const { next, error } = await props.searchParams;
  const nextPath = safeNextPath(next);

  if (await isAdminSessionValid()) {
    redirect(nextPath);
  }

  const errorMessage = error
    ? (ERROR_MESSAGES[error] ?? ERROR_MESSAGES.failed)
    : null;
  const startHref = `/api/auth/google/start?next=${encodeURIComponent(nextPath)}`;

  return (
    <main className="min-h-screen flex items-center justify-center px-4">
      <div className="w-full max-w-sm">
        <div className="mb-8 text-center">
          <h1 className="text-2xl font-semibold tracking-tight">koom admin</h1>
          <p className="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
            Sign in with Google to manage your recordings.
          </p>
        </div>

        <div className="space-y-4">
          {errorMessage && (
            <p
              data-testid="login-error"
              className="text-sm text-red-400"
              role="alert"
            >
              {errorMessage}
            </p>
          )}

          <a
            href={startHref}
            data-testid="google-sign-in"
            className="block w-full rounded-md bg-sky-600 px-4 py-2 text-center text-sm font-medium text-white shadow hover:bg-sky-500"
          >
            Sign in with Google
          </a>
        </div>
      </div>
    </main>
  );
}
