/**
 * Canonical admin login page.
 *
 * Server component wrapper — the actual form logic lives in a
 * client component because it needs to handle the submit event,
 * POST to /api/admin/session, and redirect on success.
 *
 * If the visitor already has a valid session cookie, they're
 * bounced straight to / so hitting the login URL while already
 * logged in isn't a dead end.
 */

import { redirect } from "next/navigation";
import type { ReactElement } from "react";

import { isAdminSessionValid } from "@/lib/auth/session";

import { LoginForm } from "./login-form";

export const dynamic = "force-dynamic";

export default async function LoginPage(): Promise<ReactElement> {
  if (await isAdminSessionValid()) {
    redirect("/");
  }

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-100 flex items-center justify-center px-4">
      <div className="w-full max-w-sm">
        <div className="mb-8 text-center">
          <h1 className="text-2xl font-semibold tracking-tight">koom admin</h1>
          <p className="mt-2 text-sm text-zinc-400">
            Enter the admin secret to manage your recordings.
          </p>
        </div>
        <LoginForm />
      </div>
    </main>
  );
}
