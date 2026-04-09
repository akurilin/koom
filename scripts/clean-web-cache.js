#!/usr/bin/env node

/**
 * Remove generated web-app artifacts that are safe to recreate.
 *
 * This is intentionally narrower than "delete everything under web/".
 * It wipes caches and test output, but leaves installed packages,
 * environment files, and source code untouched.
 *
 * Safety guard: if a live `next dev` server is using this workspace,
 * refuse to delete `.next` out from under it.
 */

const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..");
const webRoot = path.join(repoRoot, "web");
const nextDevLockPath = path.join(webRoot, ".next", "dev", "lock");

const targets = [
  ".next",
  "node_modules/.vite",
  "test-results",
  "playwright-report",
  "coverage",
  ".turbo",
];

const liveNextPid = readLiveNextDevPid(nextDevLockPath);
if (liveNextPid !== null) {
  console.error(
    `[web:clean] Refusing to clean while \`next dev\` is running (PID ${liveNextPid}). ` +
      `Stop the web dev server and run this command again.`,
  );
  process.exit(1);
}

let removedCount = 0;

for (const relativeTarget of targets) {
  const absoluteTarget = path.join(webRoot, relativeTarget);
  if (!fs.existsSync(absoluteTarget)) continue;

  fs.rmSync(absoluteTarget, {
    recursive: true,
    force: true,
    maxRetries: 3,
    retryDelay: 100,
  });
  console.log(`[web:clean] removed web/${relativeTarget}`);
  removedCount += 1;
}

if (removedCount === 0) {
  console.log("[web:clean] nothing to remove");
} else {
  console.log(`[web:clean] cleanup complete (${removedCount} paths removed)`);
}

function readLiveNextDevPid(lockPath) {
  if (!fs.existsSync(lockPath)) return null;

  let content;
  try {
    content = fs.readFileSync(lockPath, "utf8");
  } catch (err) {
    console.warn("[web:clean] could not read next dev lock file:", err);
    return null;
  }

  let pid = null;
  try {
    const parsed = JSON.parse(content);
    if (typeof parsed.pid === "number") {
      pid = parsed.pid;
    }
  } catch {
    console.warn(
      "[web:clean] next dev lock was unparseable; treating it as stale",
    );
    return null;
  }

  if (pid === null) return null;

  try {
    process.kill(pid, 0);
    return pid;
  } catch {
    console.log(`[web:clean] ignoring stale next dev lock for dead PID ${pid}`);
    return null;
  }
}
