/**
 * Generate three distinct MP4 fixtures via FFmpeg for the E2E
 * test. Each has a different alphabetical prefix, duration, and
 * resolution so the recordings page sort assertions
 * (sort-by-name, sort-by-size, sort-by-duration) produce
 * meaningfully different orderings.
 *
 * Files are written to a per-process temp directory so parallel
 * test runs can't clash on the filesystem. The whole directory
 * is removed in cleanupFixtures() regardless of test outcome.
 *
 * FFmpeg is required and must be on PATH. The check happens at
 * the top of generateFixtures() so failures are early and clear.
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export interface FixtureSpec {
  /** Filename only — what gets stored as `original_filename`. */
  filename: string;
  /** Absolute path on disk where the MP4 was generated. */
  localPath: string;
  /** Final size in bytes (populated after generation). */
  sizeBytes: number;
  /** Encoded video duration in whole seconds. */
  durationSeconds: number;
}

/**
 * Per-process scratch directory for fixture MP4s. Override via
 * `KOOM_TEST_FIXTURES_DIR` if you want them somewhere predictable
 * for inspection.
 */
const FIXTURES_DIR =
  process.env.KOOM_TEST_FIXTURES_DIR ??
  path.join(os.tmpdir(), `koom-e2e-fixtures-${process.pid}`);

/**
 * Three distinct fixture MP4s. Names start with a / m / z so
 * sort-by-name produces a non-trivial ordering. Sizes and
 * durations also differ so sort-by-size and sort-by-duration
 * each produce a different ordering from sort-by-name.
 */
const SPECS: ReadonlyArray<{
  filename: string;
  durationSeconds: number;
  width: number;
  height: number;
}> = [
  {
    filename: "koom_e2e_a_long.mp4",
    durationSeconds: 3,
    width: 640,
    height: 480,
  },
  {
    filename: "koom_e2e_m_medium.mp4",
    durationSeconds: 2,
    width: 320,
    height: 240,
  },
  {
    filename: "koom_e2e_z_short.mp4",
    durationSeconds: 1,
    width: 160,
    height: 120,
  },
];

export async function generateFixtures(): Promise<FixtureSpec[]> {
  await ensureFFmpeg();
  await mkdir(FIXTURES_DIR, { recursive: true });

  const out: FixtureSpec[] = [];
  for (const spec of SPECS) {
    const localPath = path.join(FIXTURES_DIR, spec.filename);
    await runFFmpeg([
      "-y",
      "-f",
      "lavfi",
      "-i",
      `color=c=steelblue:s=${spec.width}x${spec.height}:r=10:d=${spec.durationSeconds}`,
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-pix_fmt",
      "yuv420p",
      "-movflags",
      "+faststart",
      localPath,
    ]);
    const fileStat = await stat(localPath);
    out.push({
      filename: spec.filename,
      localPath,
      sizeBytes: fileStat.size,
      durationSeconds: spec.durationSeconds,
    });
  }
  return out;
}

export async function cleanupFixtures(): Promise<void> {
  if (existsSync(FIXTURES_DIR)) {
    await rm(FIXTURES_DIR, { recursive: true, force: true });
  }
}

async function ensureFFmpeg(): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn("ffmpeg", ["-version"], { stdio: "ignore" });
    proc.on("error", () =>
      reject(
        new Error(
          "ffmpeg is required for E2E tests but was not found on PATH. " +
            "Install it via `brew install ffmpeg` (macOS) or your platform's package manager.",
        ),
      ),
    );
    proc.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg -version exited with code ${code}`));
    });
  });
}

async function runFFmpeg(args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn("ffmpeg", args, { stdio: "ignore" });
    proc.on("error", reject);
    proc.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg exited with code ${code}`));
    });
  });
}
