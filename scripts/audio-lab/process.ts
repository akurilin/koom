/*
 * Renders a clip through every chain in lab.ts.
 *
 * Layout of one clip directory:
 *
 *   meta.json                 title, description, source
 *   input.<ext>               what was uploaded or seeded (audio or video)
 *   prep.wav                  mono 48 kHz float, the common starting point
 *   denoise/<key>.wav         cached denoiser outputs, shared across chains
 *   out/<chainKey>.wav        the files the listening page plays
 *   out/<chainKey>.json       loudness metrics for that output
 *
 * Every output keeps prep.wav's exact length and timing so the page can
 * switch between variants mid-playback without a jump.
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import {
  mkdir,
  readdir,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import path from "node:path";

import {
  CACHE_DIR,
  CHAINS,
  type Chain,
  chainKey,
  type Denoiser,
  denoiseKey,
  ENVS_DIR,
  HF_HOME,
  ISOLATE_BIN,
  ISOLATE_SOURCE,
  type Leveler,
  PYTHON_DIR,
  PYTHON_HELPERS,
  type PythonHelper,
  RNNOISE_MODEL,
  TARGET_LUFS,
  TARGET_TRUE_PEAK,
} from "./lab";

export interface Loudness {
  integrated: number;
  truePeak: number;
  range: number;
}

export interface OutputMetrics extends Loudness {
  /** Fixed gain the leveler applied, when it applied one. */
  gainDB: number | null;
}

/** How long a denoiser took on a clip, excluding model loading. */
export interface DenoiseSpeed {
  processSeconds: number;
  audioSeconds: number;
}

export async function run(
  command: string,
  args: string[],
  options: { env?: NodeJS.ProcessEnv; cwd?: string } = {},
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve({ stdout, stderr });
      else
        reject(
          new Error(
            `${path.basename(command)} exited ${code}: ${stderr.trim().split("\n").slice(-5).join("\n")}`,
          ),
        );
    });
  });
}

export function ffmpeg(args: string[]) {
  return run("ffmpeg", ["-y", "-nostdin", "-hide_banner", ...args]);
}

// ---------------------------------------------------------------------------
// Tools

export interface Tools {
  apple: boolean;
  rnnoise: boolean;
  fft: boolean;
  /** Python helpers whose uv environment is installed. */
  python: Record<PythonHelper, boolean>;
}

/** Compiles isolate.swift when the binary is missing or older than it. */
export async function ensureIsolateBuilt(): Promise<boolean> {
  try {
    const sourceTime = (await stat(ISOLATE_SOURCE)).mtimeMs;
    const binaryTime = existsSync(ISOLATE_BIN)
      ? (await stat(ISOLATE_BIN)).mtimeMs
      : 0;
    if (binaryTime < sourceTime) {
      await mkdir(path.dirname(ISOLATE_BIN), { recursive: true });
      console.log("Compiling isolate.swift ...");
      await run("swiftc", ["-O", ISOLATE_SOURCE, "-o", ISOLATE_BIN]);
    }
    return true;
  } catch (error) {
    console.error(`Apple voice isolation unavailable: ${String(error)}`);
    return false;
  }
}

export async function detectTools(): Promise<Tools> {
  return {
    apple: await ensureIsolateBuilt(),
    rnnoise: existsSync(RNNOISE_MODEL),
    fft: true,
    python: Object.fromEntries(
      PYTHON_HELPERS.map((helper) => [
        helper,
        existsSync(path.join(ENVS_DIR, helper, "pyvenv.cfg")),
      ]),
    ) as Record<PythonHelper, boolean>,
  };
}

function denoiserAvailable(denoise: Denoiser | null, tools: Tools): boolean {
  if (!denoise) return true;
  if (denoise.kind === "python") return tools.python[denoise.helper];
  return tools[denoise.kind];
}

/** Environment for a helper's uv project: its env and model caches. */
export function pythonEnv(helper: PythonHelper): NodeJS.ProcessEnv {
  return {
    ...process.env,
    UV_PROJECT_ENVIRONMENT: path.join(ENVS_DIR, helper),
    HF_HOME,
    DPDFNET_CACHE_DIR: path.join(CACHE_DIR, "dpdfnet"),
  };
}

/**
 * Runs client/Resources/denoisers/<helper>/enhance.py as a separate process. Returns the
 * processing time it reports (model loading excluded).
 */
async function runPythonHelper(
  helper: PythonHelper,
  input: string,
  output: string,
): Promise<number> {
  const project = path.join(PYTHON_DIR, helper);
  // ClearVoice downloads checkpoints relative to the working directory.
  const cwd = path.join(CACHE_DIR, helper);
  await mkdir(cwd, { recursive: true });
  const { stdout } = await run(
    "uv",
    [
      "run",
      "--frozen",
      "--project",
      project,
      "python",
      path.join(project, "enhance.py"),
      input,
      output,
    ],
    { env: pythonEnv(helper), cwd },
  );
  const report = stdout
    .trim()
    .split("\n")
    .reverse()
    .find((line) => line.startsWith("{"));
  if (!report) throw new Error(`${helper} printed no timing report`);
  return Number(JSON.parse(report).process_seconds);
}

// ---------------------------------------------------------------------------
// Measurement

export async function measureLoudness(file: string): Promise<Loudness> {
  const { stderr } = await ffmpeg([
    "-nostats",
    "-i",
    file,
    "-af",
    "loudnorm=print_format=json",
    "-f",
    "null",
    "-",
  ]);
  const json = stderr.slice(
    stderr.lastIndexOf("{"),
    stderr.lastIndexOf("}") + 1,
  );
  const values = JSON.parse(json) as Record<string, string>;
  return {
    integrated: Number(values.input_i),
    truePeak: Number(values.input_tp),
    range: Number(values.input_lra),
  };
}

// ---------------------------------------------------------------------------
// Stages

async function prepare(clipDir: string): Promise<string> {
  const prepPath = path.join(clipDir, "prep.wav");
  if (existsSync(prepPath)) return prepPath;
  const input = (await readdir(clipDir)).find((name) =>
    name.startsWith("input."),
  );
  if (!input) throw new Error(`${clipDir} has no input file`);
  await ffmpeg([
    "-loglevel",
    "error",
    "-i",
    path.join(clipDir, input),
    "-map",
    "0:a:0",
    "-ac",
    "1",
    "-ar",
    "48000",
    "-c:a",
    "pcm_f32le",
    prepPath,
  ]);
  return prepPath;
}

async function denoise(
  clipDir: string,
  prepPath: string,
  denoiser: Denoiser,
): Promise<string> {
  const outputPath = path.join(
    clipDir,
    "denoise",
    `${denoiseKey(denoiser)}.wav`,
  );
  if (existsSync(outputPath)) return outputPath;
  await mkdir(path.dirname(outputPath), { recursive: true });
  const partial = `${outputPath}.partial.wav`;
  const length = await sampleCount(prepPath);
  const started = Date.now();
  let processSeconds: number | null = null;

  switch (denoiser.kind) {
    case "python":
      processSeconds = await runPythonHelper(
        denoiser.helper,
        prepPath,
        partial,
      );
      break;
    case "apple":
      await run(ISOLATE_BIN, [
        prepPath,
        partial,
        "--model",
        denoiser.model,
        "--mix",
        String(denoiser.mix),
      ]);
      break;
    case "rnnoise":
      await ffmpeg([
        "-loglevel",
        "error",
        "-i",
        prepPath,
        "-af",
        `arnndn=m=${RNNOISE_MODEL},${realign(480, length)}`,
        "-c:a",
        "pcm_f32le",
        partial,
      ]);
      break;
    case "fft":
      await ffmpeg([
        "-loglevel",
        "error",
        "-i",
        prepPath,
        "-af",
        `highpass=f=80,afftdn=nr=12:nf=-30:tn=1,${realign(1199, length)}`,
        "-c:a",
        "pcm_f32le",
        partial,
      ]);
      break;
  }
  const speed: DenoiseSpeed = {
    // In-process tools: wall time, including process startup.
    processSeconds: processSeconds ?? (Date.now() - started) / 1000,
    audioSeconds: length / 48_000,
  };
  await writeFile(speedPath(outputPath), JSON.stringify(speed));
  await rename(partial, outputPath);
  return outputPath;
}

function speedPath(denoisedPath: string): string {
  return denoisedPath.replace(/\.wav$/, ".json");
}

async function readSpeed(
  clipDir: string,
  denoiser: Denoiser | null,
): Promise<DenoiseSpeed | undefined> {
  if (!denoiser) return undefined;
  const file = path.join(clipDir, "denoise", `${denoiseKey(denoiser)}.json`);
  if (!existsSync(file)) return undefined;
  return JSON.parse(await readFile(file, "utf8"));
}

/**
 * Undoes a filter's fixed processing delay by dropping the first `delay`
 * samples, then pads or trims to exactly `length` samples (arnndn also
 * rounds its output up to whole 480-sample frames). Delays at 48 kHz were
 * measured by cross-correlating outputs against prep.wav and are the same
 * on every clip: arnndn 480, afftdn 1199.
 */
function realign(delay: number, length: number): string {
  return `atrim=start_sample=${delay},asetpts=PTS-STARTPTS,apad=whole_len=${length},atrim=end_sample=${length}`;
}

async function sampleCount(file: string): Promise<number> {
  const { stdout } = await run("ffprobe", [
    "-v",
    "error",
    "-select_streams",
    "a:0",
    "-show_entries",
    "stream=duration_ts",
    "-of",
    "csv=p=0",
    file,
  ]);
  const samples = Number(stdout.trim());
  if (!Number.isInteger(samples) || samples <= 0) {
    throw new Error(`could not read the sample count of ${file}`);
  }
  return samples;
}

function dbToLinear(db: number): number {
  return 10 ** (db / 20);
}

/** Upsampled so the limiter also catches inter-sample peaks. */
function limiterFilter(): string {
  const limit = dbToLinear(TARGET_TRUE_PEAK).toFixed(4);
  return `aresample=192000,alimiter=limit=${limit}:attack=5:release=50:level=0:latency=1,aresample=48000`;
}

/** koom's LoudnessNormalizer.normalizationGain, or null to leave as-is. */
function koomStaticGain(loudness: Loudness): number | null {
  if (!Number.isFinite(loudness.integrated)) return null;
  if (Math.abs(loudness.integrated - TARGET_LUFS) <= 1) return null;
  const desired = TARGET_LUFS - loudness.integrated;
  let gain = desired;
  if (desired > 0 && Number.isFinite(loudness.truePeak)) {
    gain = Math.min(desired, Math.max(0, TARGET_TRUE_PEAK - loudness.truePeak));
  }
  return Math.abs(gain) < 0.1 ? null : gain;
}

async function level(
  inputPath: string,
  outputPath: string,
  leveler: Leveler | null,
): Promise<number | null> {
  const encode = ["-c:a", "pcm_s16le", "-ar", "48000"];
  if (!leveler) {
    await ffmpeg([
      "-loglevel",
      "error",
      "-i",
      inputPath,
      ...encode,
      outputPath,
    ]);
    return null;
  }

  let source = inputPath;
  let leveled: string | null = null;
  if (leveler.kind === "dynaudnorm-limiter") {
    // ~7.5 s Gaussian window: evens out "leaned back" vs "leaned in"
    // stretches without pumping between words; at most +18 dB.
    leveled = `${outputPath}.leveled.wav`;
    await ffmpeg([
      "-loglevel",
      "error",
      "-i",
      inputPath,
      "-af",
      "dynaudnorm=framelen=500:gausssize=15:peak=0.9:maxgain=8",
      "-c:a",
      "pcm_f32le",
      leveled,
    ]);
    source = leveled;
  }

  try {
    const loudness = await measureLoudness(source);
    let gain: number | null;
    let filter: string;
    if (leveler.kind === "koom-static") {
      gain = koomStaticGain(loudness);
      filter = gain === null ? "anull" : `volume=${gain.toFixed(2)}dB`;
    } else {
      gain = Number.isFinite(loudness.integrated)
        ? TARGET_LUFS - loudness.integrated
        : 0;
      filter = `volume=${gain.toFixed(2)}dB,${limiterFilter()}`;
    }
    await ffmpeg([
      "-loglevel",
      "error",
      "-i",
      source,
      "-af",
      filter,
      ...encode,
      outputPath,
    ]);

    // Limiting peaky speech takes loudness off (often 1-2 LU), so add the
    // shortfall once and re-limit. That lands near the target, the way a
    // product would have to, at the cost of a bit more limiting.
    if (leveler.kind !== "koom-static" && gain !== null) {
      const result = await measureLoudness(outputPath);
      const shortfall = TARGET_LUFS - result.integrated;
      if (Number.isFinite(shortfall) && shortfall > 0.3) {
        gain += shortfall;
        await ffmpeg([
          "-loglevel",
          "error",
          "-i",
          source,
          "-af",
          `volume=${gain.toFixed(2)}dB,${limiterFilter()}`,
          ...encode,
          outputPath,
        ]);
      }
    }
    return gain;
  } finally {
    if (leveled) await rm(leveled, { force: true });
  }
}

// ---------------------------------------------------------------------------
// Clips

export interface ClipMeta {
  id: string;
  title: string;
  description?: string;
  source?: string;
  createdAt: string;
}

export type VariantStatus = "ready" | "pending" | "unavailable" | "failed";

export interface Variant {
  chainId: string;
  status: VariantStatus;
  url?: string;
  metrics?: OutputMetrics;
  speed?: DenoiseSpeed;
  error?: string;
}

export async function readMeta(clipDir: string): Promise<ClipMeta> {
  return JSON.parse(await readFile(path.join(clipDir, "meta.json"), "utf8"));
}

function outputPaths(clipDir: string, chain: Chain) {
  const base = path.join(clipDir, "out", chainKey(chain));
  return {
    wav: `${base}.wav`,
    metrics: `${base}.json`,
    error: `${base}.error`,
  };
}

export async function variantsFor(
  clipDir: string,
  clipId: string,
  tools: Tools,
): Promise<Variant[]> {
  return Promise.all(
    CHAINS.map(async (chain): Promise<Variant> => {
      const paths = outputPaths(clipDir, chain);
      if (existsSync(paths.wav) && existsSync(paths.metrics)) {
        return {
          chainId: chain.id,
          status: "ready",
          url: `/clips/${clipId}/out/${path.basename(paths.wav)}`,
          metrics: JSON.parse(await readFile(paths.metrics, "utf8")),
          speed: await readSpeed(clipDir, chain.denoise),
        };
      }
      if (existsSync(paths.error)) {
        return {
          chainId: chain.id,
          status: "failed",
          error: await readFile(paths.error, "utf8"),
        };
      }
      if (!denoiserAvailable(chain.denoise, tools)) {
        return { chainId: chain.id, status: "unavailable" };
      }
      return { chainId: chain.id, status: "pending" };
    }),
  );
}

/** Deletes renders left over from chains that were edited or removed. */
async function removeStaleRenders(clipDir: string): Promise<void> {
  const liveOutputs = new Set(CHAINS.map(chainKey));
  const liveDenoises = new Set(
    CHAINS.map((chain) => denoiseKey(chain.denoise)),
  );
  const sweep = async (dir: string, isLive: (base: string) => boolean) => {
    if (!existsSync(dir)) return;
    for (const name of await readdir(dir)) {
      const base = name.replace(/\.(partial\.wav|wav|json|error)$/, "");
      if (!isLive(base)) await rm(path.join(dir, name), { force: true });
    }
  };
  await sweep(path.join(clipDir, "out"), (base) => liveOutputs.has(base));
  await sweep(path.join(clipDir, "denoise"), (base) => liveDenoises.has(base));
}

/** Renders every missing, available chain for one clip. */
export async function processClip(
  clipDir: string,
  tools: Tools,
): Promise<void> {
  const prepPath = await prepare(clipDir);
  await mkdir(path.join(clipDir, "out"), { recursive: true });
  await removeStaleRenders(clipDir);

  for (const chain of CHAINS) {
    const paths = outputPaths(clipDir, chain);
    if (existsSync(paths.wav) && existsSync(paths.metrics)) continue;
    if (existsSync(paths.error)) continue;
    if (!denoiserAvailable(chain.denoise, tools)) continue;

    try {
      const denoised = chain.denoise
        ? await denoise(clipDir, prepPath, chain.denoise)
        : prepPath;
      const partial = `${paths.wav}.partial.wav`;
      const gainDB = await level(denoised, partial, chain.level);
      const loudness = await measureLoudness(partial);
      const metrics: OutputMetrics = { ...loudness, gainDB };
      await writeFile(paths.metrics, JSON.stringify(metrics));
      await rename(partial, paths.wav);
    } catch (error) {
      console.error(
        `[${path.basename(clipDir)}] ${chain.id} failed: ${String(error)}`,
      );
      await writeFile(paths.error, String(error));
    }
  }
}
