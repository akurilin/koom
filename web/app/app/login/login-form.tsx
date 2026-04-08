/**
 * Client-side login form. Submits the admin secret to the
 * /api/admin/session endpoint built in round D-2, and redirects
 * to /app/recordings on success.
 *
 * Uses `router.replace` + `router.refresh` on success so the
 * browser back button doesn't return to the login page after
 * the user has authenticated — refresh is needed so the server
 * component on the next page re-reads the session cookie we just
 * set.
 */

"use client";

import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";

export function LoginForm() {
  const router = useRouter();
  const [secret, setSecret] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  async function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (isSubmitting) return;

    setError(null);
    setIsSubmitting(true);

    try {
      const res = await fetch("/api/admin/session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ secret }),
      });

      if (res.status === 401) {
        setError("Invalid admin secret.");
        setIsSubmitting(false);
        return;
      }
      if (!res.ok) {
        const body = (await res.json().catch(() => ({}))) as {
          error?: string;
        };
        setError(body.error ?? `Login failed (HTTP ${res.status})`);
        setIsSubmitting(false);
        return;
      }

      // Success. Replace the history entry so back-button doesn't
      // return to login, and refresh so the destination server
      // component re-reads the cookie store.
      router.replace("/app/recordings");
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Login failed");
      setIsSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label
          htmlFor="admin-secret"
          className="block text-sm font-medium text-zinc-300 mb-2"
        >
          Admin secret
        </label>
        <input
          id="admin-secret"
          data-testid="admin-secret-input"
          type="password"
          autoComplete="current-password"
          required
          value={secret}
          onChange={(e) => setSecret(e.target.value)}
          className="w-full rounded-md border border-zinc-700 bg-zinc-900 px-3 py-2 text-zinc-100 placeholder:text-zinc-500 focus:border-sky-500 focus:outline-none focus:ring-2 focus:ring-sky-500/40"
          placeholder="Paste KOOM_ADMIN_SECRET"
        />
      </div>

      {error && (
        <p
          data-testid="login-error"
          className="text-sm text-red-400"
          role="alert"
        >
          {error}
        </p>
      )}

      <button
        type="submit"
        data-testid="login-button"
        disabled={isSubmitting || secret.length === 0}
        className="w-full rounded-md bg-sky-600 px-4 py-2 text-sm font-medium text-white shadow hover:bg-sky-500 disabled:cursor-not-allowed disabled:opacity-60"
      >
        {isSubmitting ? "Logging in…" : "Log in"}
      </button>
    </form>
  );
}
