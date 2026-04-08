/**
 * Playwright globalSetup — runs once before the test suite and
 * before Playwright starts the Next.js webServer.
 *
 * Sole job right now: remove a stale `next dev` lock file if one
 * exists and refers to a dead PID. Next.js 16 writes
 * `.next/dev/lock` when a dev server starts, and cleans it up on
 * graceful shutdown. A hard kill (including "test failed, tear
 * down the web server") can leave the lock behind, which blocks
 * subsequent `next dev` invocations with a misleading
 * "Another next dev server is already running" error pointing at
 * the dead PID.
 *
 * We only remove the lock if its recorded PID is genuinely not
 * running. If there IS a real dev server running from this
 * directory (user's own instance on port 3000, say), we leave
 * the lock alone — Next.js will then refuse to start and the
 * user sees an actionable message telling them which PID to
 * kill.
 */

import { existsSync, readFileSync, unlinkSync } from "node:fs";
import path from "node:path";

const LOCK_PATH = path.resolve(__dirname, "..", "..", ".next", "dev", "lock");

export default async function globalSetup(): Promise<void> {
  if (!existsSync(LOCK_PATH)) return;

  let content: string;
  try {
    content = readFileSync(LOCK_PATH, "utf-8");
  } catch (err) {
    console.warn(
      "[playwright globalSetup] could not read next dev lock file:",
      err,
    );
    return;
  }

  let pid: number | null = null;
  try {
    const parsed = JSON.parse(content) as { pid?: unknown };
    if (typeof parsed.pid === "number") pid = parsed.pid;
  } catch {
    // Unparseable lock file — treat as stale and remove.
  }

  if (pid === null) {
    console.log(
      "[playwright globalSetup] removing unparseable next dev lock file",
    );
    safeUnlink(LOCK_PATH);
    return;
  }

  // process.kill(pid, 0) is a standard "does this process exist"
  // probe: it throws ESRCH if the process is gone, or EPERM if
  // the process exists but is owned by a different user (which
  // also means we should leave it alone).
  let alive = false;
  try {
    process.kill(pid, 0);
    alive = true;
  } catch {
    alive = false;
  }

  if (alive) {
    // Leave the lock alone; Next.js will refuse to start and the
    // user will get an actionable error.
    console.log(
      `[playwright globalSetup] next dev lock points at live PID ${pid}; leaving alone`,
    );
    return;
  }

  console.log(
    `[playwright globalSetup] removing stale next dev lock (dead PID ${pid})`,
  );
  safeUnlink(LOCK_PATH);
}

function safeUnlink(p: string): void {
  try {
    unlinkSync(p);
  } catch (err) {
    console.warn(`[playwright globalSetup] failed to unlink ${p}:`, err);
  }
}
