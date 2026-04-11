/**
 * Next.js instrumentation hook.
 *
 * The `register` function runs once when a new Next.js server
 * instance boots, before any request is handled. We use it to run
 * a read-only preflight check that verifies Postgres and Cloudflare
 * R2 are reachable. If they're not, we crash the process with a
 * clear, actionable error message so the developer doesn't discover
 * the problem via a cryptic 500 on their first request.
 *
 * Only runs in:
 *
 *   - the Node.js runtime (the checks use `pg` and `@aws-sdk`,
 *     neither of which work on the Edge runtime)
 *   - development mode (production has its own observability and
 *     retry semantics; we don't want a transient outage to crash
 *     every cold start on Vercel)
 */

export async function register(): Promise<void> {
  if (process.env.NEXT_RUNTIME !== "nodejs") return;
  if (process.env.NODE_ENV !== "development") return;

  const { runPreflight } = await import("./lib/startup/preflight");
  await runPreflight();
}
