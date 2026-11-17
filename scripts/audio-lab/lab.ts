/*
 * Audio lab configuration: where clips live and which cleanup chains each
 * clip is rendered through.
 *
 * A chain is one denoiser (or none) followed by one leveler (or none).
 * Rendered outputs are cached under a hash of the chain's settings, so
 * editing a chain here re-renders just that chain on the next server start
 * while older ratings for it stay attached to its id.
 */

import { createHash } from "node:crypto";
import path from "node:path";

export const LAB_DIR = path.resolve(__dirname);
export const DATA_DIR = path.join(LAB_DIR, ".data");
export const CLIPS_DIR = path.join(DATA_DIR, "clips");
export const BIN_DIR = path.join(DATA_DIR, "bin");
export const MODELS_DIR = path.join(DATA_DIR, "models");
export const CACHE_DIR = path.join(DATA_DIR, "cache");
// Tracked in git, unlike the rest of .data: the ratings are the only part
// of the lab that can't be regenerated (npm run audio-lab:seed rebuilds
// the same starter clips from pinned URLs, and renders are cached builds).
export const RATINGS_FILE = path.join(LAB_DIR, "ratings.json");

export const ISOLATE_SOURCE = path.join(LAB_DIR, "isolate.swift");
export const ISOLATE_BIN = path.join(BIN_DIR, "isolate");
export const RNNOISE_MODEL = path.join(MODELS_DIR, "bd.rnnn");

/**
 * Python models run as separate helper processes, the way the koom client
 * runs them: client/Resources/denoisers/<helper>/enhance.py inside its own
 * pinned uv environment, here under .data/envs/<helper>
 * (`npm run audio-lab:models`).
 */
export const PYTHON_HELPERS = ["dpdfnet", "clearvoice", "sidon"] as const;
export type PythonHelper = (typeof PYTHON_HELPERS)[number];
// Shared with the koom client, which installs the same helpers for
// noise removal; one copy keeps what ships identical to what was rated.
export const PYTHON_DIR = path.join(
  LAB_DIR,
  "..",
  "..",
  "client",
  "Resources",
  "denoisers",
);
export const ENVS_DIR = path.join(DATA_DIR, "envs");
export const HF_HOME = path.join(DATA_DIR, "hf");

/** Matches koom's LoudnessNormalizer. */
export const TARGET_LUFS = -16;
export const TARGET_TRUE_PEAK = -1.5;

export type Denoiser =
  | { kind: "apple"; model: "hq" | "standard"; mix: number }
  | { kind: "rnnoise" }
  | { kind: "fft" }
  | { kind: "python"; helper: PythonHelper };

export type Leveler =
  /** koom today: one fixed gain, boosts capped by true-peak headroom. */
  | { kind: "koom-static" }
  /** Full fixed gain to the target; a fast limiter catches the peaks. */
  | { kind: "static-limiter" }
  /** Slow automatic leveling first, then static gain and limiter. */
  | { kind: "dynaudnorm-limiter" };

export interface Chain {
  id: string;
  label: string;
  denoise: Denoiser | null;
  level: Leveler | null;
  /**
   * Clearly lost in listening tests: hidden in the UI unless "Show
   * retired" is on. Still rendered (they're the cheap chains) and their
   * ratings kept, so turning them back on costs nothing.
   */
  retired?: boolean;
}

export const CHAINS: Chain[] = [
  {
    id: "original",
    label: "Original (unprocessed)",
    denoise: null,
    level: null,
  },
  {
    id: "koom-today",
    label: "koom today (static gain)",
    denoise: null,
    level: { kind: "koom-static" },
    retired: true,
  },
  {
    id: "limiter",
    label: "Static gain + limiter",
    denoise: null,
    level: { kind: "static-limiter" },
    retired: true,
  },
  {
    id: "leveler",
    label: "Auto-leveler + limiter",
    denoise: null,
    level: { kind: "dynaudnorm-limiter" },
    retired: true,
  },
  {
    id: "apple-hq",
    label: "Apple voice isolation (HQ) + limiter",
    denoise: { kind: "apple", model: "hq", mix: 100 },
    level: { kind: "static-limiter" },
  },
  {
    id: "apple-hq-blend",
    label: "Apple voice isolation (HQ, 70% wet) + limiter",
    denoise: { kind: "apple", model: "hq", mix: 70 },
    level: { kind: "static-limiter" },
    retired: true,
  },
  {
    id: "apple-standard",
    label: "Apple voice isolation (standard) + limiter",
    denoise: { kind: "apple", model: "standard", mix: 100 },
    level: { kind: "static-limiter" },
  },
  {
    id: "apple-hq-leveler",
    label: "Apple voice isolation (HQ) + auto-leveler",
    denoise: { kind: "apple", model: "hq", mix: 100 },
    level: { kind: "dynaudnorm-limiter" },
  },
  {
    id: "rnnoise",
    label: "RNNoise (ffmpeg arnndn) + limiter",
    denoise: { kind: "rnnoise" },
    level: { kind: "static-limiter" },
    retired: true,
  },
  {
    id: "fft",
    label: "FFT denoise (ffmpeg afftdn) + limiter",
    denoise: { kind: "fft" },
    level: { kind: "static-limiter" },
    retired: true,
  },
  {
    id: "dpdfnet",
    label: "DPDFNet (48 kHz, dpdfnet8) + limiter",
    denoise: { kind: "python", helper: "dpdfnet" },
    level: { kind: "static-limiter" },
  },
  {
    id: "clearvoice",
    label: "ClearerVoice MossFormer2 (48 kHz) + limiter",
    denoise: { kind: "python", helper: "clearvoice" },
    level: { kind: "static-limiter" },
  },
  {
    id: "sidon",
    label: "Sidon (generative restoration) + limiter",
    denoise: { kind: "python", helper: "sidon" },
    level: { kind: "static-limiter" },
  },
];

/** Bump to invalidate every cached render after a processing change. */
const PROCESSING_VERSION = 4;

function hash(value: unknown): string {
  return createHash("sha256")
    .update(JSON.stringify({ PROCESSING_VERSION, value }))
    .digest("hex")
    .slice(0, 12);
}

export function denoiseKey(denoise: Denoiser | null): string {
  return denoise ? `${denoise.kind}-${hash(denoise)}` : "none";
}

export function chainKey(chain: Chain): string {
  return `${chain.id}-${hash({ denoise: chain.denoise, level: chain.level })}`;
}
