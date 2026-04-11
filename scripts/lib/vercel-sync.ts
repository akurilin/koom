/*
 * scripts/lib/vercel-sync.ts
 *
 * Shared comparison logic for Vercel production environment variables.
 * Both the standalone `scripts/vercel-sync.ts` CLI and the doctor
 * (`scripts/doctor.ts`) call into `computeSyncDiff()` so there is one
 * canonical source of truth for "what should be in Vercel" and "how
 * do we derive it from the local setup."
 *
 * Design goals:
 *
 *   - Pure. This module does HTTP and file reads exactly when asked
 *     to; it doesn't reach into the environment or hard-code paths.
 *     Callers hand it a `SyncContext` and get back structured
 *     results.
 *
 *   - Read-only. `computeSyncDiff()` never issues a `POST` or `PATCH`
 *     against the Vercel API. Writing will be layered on later in
 *     `applySyncDiff()` once the dry-run behavior is trusted.
 *
 *   - Honest about unknowns. Vercel's `sensitive` env var type cannot
 *     be read back through the API, so any sensitive variable gets
 *     marked `opaque` — sync --write would unconditionally overwrite
 *     it, but we cannot tell the user whether it's actually drifted.
 *     The CLI and the doctor both surface this distinction.
 */

import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";

// ────────────────────────────────────────────────────────────────────
// Expected variable spec
// ────────────────────────────────────────────────────────────────────

/**
 * Where the desired value for a given Vercel env var comes from. Each
 * kind is handled by a dedicated branch in `resolveDesiredValue()`.
 */
export type VarSource =
  | { kind: "env-local"; envKey: string }
  | { kind: "supabase-pooler"; passwordEnvKey: string }
  | { kind: "vercel-primary-domain" };

/**
 * The canonical list of env vars that koom's production Vercel
 * deployment needs. Adding a new variable in the web app should
 * update this list and everything downstream (doctor report, CLI
 * output, future write mode) picks it up automatically.
 *
 * ORDER MATTERS for display — keep it alphabetical.
 */
export const EXPECTED_VARS: ReadonlyArray<{
  key: string;
  source: VarSource;
  humanSource: string;
}> = [
  {
    key: "DATABASE_URL",
    source: { kind: "supabase-pooler", passwordEnvKey: "SUPABASE_DB_PASSWORD" },
    humanSource: "Supabase CLI pooler URL + SUPABASE_DB_PASSWORD",
  },
  {
    key: "KOOM_ADMIN_SECRET",
    source: { kind: "env-local", envKey: "KOOM_ADMIN_SECRET" },
    humanSource: "web/.env.local",
  },
  {
    key: "KOOM_PUBLIC_BASE_URL",
    source: { kind: "vercel-primary-domain" },
    humanSource: "Vercel project primary domain",
  },
  {
    key: "R2_ACCESS_KEY_ID",
    source: { kind: "env-local", envKey: "R2_ACCESS_KEY_ID" },
    humanSource: "web/.env.local",
  },
  {
    key: "R2_ACCOUNT_ID",
    source: { kind: "env-local", envKey: "R2_ACCOUNT_ID" },
    humanSource: "web/.env.local",
  },
  {
    key: "R2_BUCKET",
    source: { kind: "env-local", envKey: "R2_BUCKET" },
    humanSource: "web/.env.local",
  },
  {
    key: "R2_PUBLIC_BASE_URL",
    source: { kind: "env-local", envKey: "R2_PUBLIC_BASE_URL" },
    humanSource: "web/.env.local",
  },
  {
    key: "R2_SECRET_ACCESS_KEY",
    source: { kind: "env-local", envKey: "R2_SECRET_ACCESS_KEY" },
    humanSource: "web/.env.local",
  },
];

const EXPECTED_KEY_SET = new Set(EXPECTED_VARS.map((v) => v.key));

// ────────────────────────────────────────────────────────────────────
// Public types
// ────────────────────────────────────────────────────────────────────

/**
 * A single variable stored in Vercel. Mirrors the shape of an entry
 * in the `/v9/projects/{id}/env` response body, narrowed to the
 * fields we actually use.
 */
export interface VercelEnvVar {
  key: string;
  value?: string; // omitted for `sensitive` type even with decrypt=true
  type: "plain" | "encrypted" | "sensitive" | "system" | "secret";
  target: string[];
  id: string;
}

/**
 * Drift status for a single variable. Each status has a distinct
 * meaning — see the comment on each branch.
 */
export type SyncStatus =
  /** Desired value matches what's currently in Vercel. No write needed. */
  | "in-sync"
  /** Desired value differs from what's in Vercel. Sync --write would update. */
  | "drift"
  /** Variable is expected but missing from Vercel. Sync --write would create. */
  | "missing-on-vercel"
  /**
   * Variable exists in Vercel as `sensitive` type, which cannot be
   * read back through the API. We cannot tell whether it's drifted.
   * Sync --write would unconditionally overwrite with the desired
   * value. Treated as "no detectable drift" for doctor reporting
   * purposes, but the CLI surfaces it explicitly so the user knows
   * why they can't see a value comparison.
   */
  | "opaque"
  /**
   * Variable exists in Vercel but isn't in our expected list. Sync
   * --write would NOT touch it (additive only). Reported so the user
   * can decide whether to manually clean it up.
   */
  | "unknown"
  /**
   * We could not compute the desired value (e.g. SUPABASE_DB_PASSWORD
   * is not set, or the Supabase CLI hasn't been linked yet). Sync
   * --write would skip this variable entirely until the blocker is
   * resolved.
   */
  | "unresolvable";

export interface VarSyncResult {
  key: string;
  status: SyncStatus;
  humanSource: string;
  notes?: string;
  /** Vercel type for the current record, if the var exists in Vercel. */
  currentType?: VercelEnvVar["type"];
  /** True if --write would create/update this variable. Used by the CLI summary. */
  wouldWrite: boolean;
}

export interface SyncSummary {
  inSync: number;
  drift: number;
  missing: number;
  opaque: number;
  unknown: number;
  unresolvable: number;
  /** Number of variables that --write would actually create/update. */
  writesNeeded: number;
  /**
   * True if there are no detectable differences. "No detectable" means
   * opaque variables are treated as OK because we can't tell either
   * way. Missing variables DO count as detectable drift.
   */
  allInSyncOrOpaque: boolean;
}

export interface SyncContext {
  /** Bearer token used to call the Vercel REST API. */
  vercelToken: string;
  /** The `prj_...` project ID (not the slug). */
  vercelProjectId: string;
  /** Parsed contents of web/.env.local (needed for R2_*, KOOM_ADMIN_SECRET, SUPABASE_DB_PASSWORD). */
  localEnv: Record<string, string>;
  /**
   * Path to the Supabase CLI-cached pooler URL file
   * (typically `supabase/.temp/pooler-url`). Optional — absence is
   * treated as `unresolvable` for DATABASE_URL.
   */
  poolerUrlPath: string;
}

export interface SyncDiff {
  results: VarSyncResult[];
  summary: SyncSummary;
  /** Set when the whole operation failed (e.g. Vercel API error). */
  error?: string;
}

// ────────────────────────────────────────────────────────────────────
// Vercel API fetchers
// ────────────────────────────────────────────────────────────────────

/**
 * Fetch every env var configured for the Vercel project. Uses
 * decrypt=true so that `encrypted` values come back as plaintext;
 * `sensitive` values still come back without a value field.
 */
export async function fetchVercelEnvVars(
  token: string,
  projectId: string,
): Promise<VercelEnvVar[]> {
  const url = new URL(
    `https://api.vercel.com/v9/projects/${encodeURIComponent(projectId)}/env?decrypt=true`,
  );
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
    },
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(
      `Vercel env vars fetch failed: HTTP ${res.status}${body ? ` — ${body}` : ""}`,
    );
  }
  const body = (await res.json()) as { envs?: VercelEnvVar[] };
  return body.envs ?? [];
}

/**
 * Fetch the verified primary domain for the Vercel project, used to
 * derive the desired `KOOM_PUBLIC_BASE_URL`. If no verified domain
 * exists, returns null so the caller can report `unresolvable`.
 */
export async function fetchVercelPrimaryDomain(
  token: string,
  projectId: string,
): Promise<string | null> {
  const url = new URL(
    `https://api.vercel.com/v9/projects/${encodeURIComponent(projectId)}/domains`,
  );
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
    },
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(
      `Vercel domains fetch failed: HTTP ${res.status}${body ? ` — ${body}` : ""}`,
    );
  }
  const body = (await res.json()) as {
    domains?: Array<{ name?: string; verified?: boolean }>;
  };
  const domains = body.domains ?? [];
  const verified = domains.find((d) => d.verified && d.name);
  const chosen = verified ?? domains.find((d) => d.name);
  return chosen?.name ?? null;
}

// ────────────────────────────────────────────────────────────────────
// Desired value resolvers
// ────────────────────────────────────────────────────────────────────

interface DesiredResolution {
  value: string | null;
  unresolvableReason?: string;
}

async function resolveDesiredValue(
  source: VarSource,
  ctx: SyncContext,
  vercelDomainCache: { value?: string | null },
): Promise<DesiredResolution> {
  if (source.kind === "env-local") {
    const v = ctx.localEnv[source.envKey];
    if (!v) {
      return {
        value: null,
        unresolvableReason: `${source.envKey} is not set in web/.env.local`,
      };
    }
    return { value: v };
  }

  if (source.kind === "supabase-pooler") {
    if (!existsSync(ctx.poolerUrlPath)) {
      return {
        value: null,
        unresolvableReason: `Supabase CLI pooler URL cache is missing (${ctx.poolerUrlPath}). Run 'supabase link --project-ref=<ref>' to generate it.`,
      };
    }
    const password = ctx.localEnv[source.passwordEnvKey];
    if (!password) {
      return {
        value: null,
        unresolvableReason: `${source.passwordEnvKey} is not set in web/.env.local`,
      };
    }
    let poolerUrlRaw: string;
    try {
      poolerUrlRaw = (await readFile(ctx.poolerUrlPath, "utf-8")).trim();
    } catch (err) {
      return {
        value: null,
        unresolvableReason: `Could not read ${ctx.poolerUrlPath}: ${
          err instanceof Error ? err.message : String(err)
        }`,
      };
    }
    let parsed: URL;
    try {
      parsed = new URL(poolerUrlRaw);
    } catch {
      return {
        value: null,
        unresolvableReason: `${ctx.poolerUrlPath} did not contain a valid URL`,
      };
    }
    // Inject the password. The Node URL API does not automatically
    // URL-encode passwords set via the `password` property — we have
    // to do it ourselves, otherwise any special char in the
    // Supabase-generated password would corrupt the connection
    // string. Vercel receives the fully-encoded canonical form.
    parsed.password = encodeURIComponent(password);
    return { value: parsed.toString() };
  }

  if (source.kind === "vercel-primary-domain") {
    // Cache the domain lookup so we only hit the API once per
    // computeSyncDiff() call, even if multiple variables resolve
    // against it (currently only KOOM_PUBLIC_BASE_URL, but future
    // additions might reuse the same source).
    if (vercelDomainCache.value === undefined) {
      vercelDomainCache.value = await fetchVercelPrimaryDomain(
        ctx.vercelToken,
        ctx.vercelProjectId,
      );
    }
    const domain = vercelDomainCache.value;
    if (!domain) {
      return {
        value: null,
        unresolvableReason: `Vercel project has no verified primary domain yet. Deploy once (or assign a domain) before running sync.`,
      };
    }
    return { value: `https://${domain}` };
  }

  // Exhaustiveness guard. TypeScript's type narrowing should already
  // prevent this, but kept as a runtime safety net in case VarSource
  // grows a new kind without updating this function.
  const _exhaustive: never = source;
  throw new Error(`Unhandled VarSource kind: ${JSON.stringify(_exhaustive)}`);
}

// ────────────────────────────────────────────────────────────────────
// The main comparison
// ────────────────────────────────────────────────────────────────────

/**
 * Compare the local source-of-truth values for every expected var
 * against what's currently live in Vercel. Returns a structured diff
 * that the caller can format as a CLI report, a doctor check, or a
 * future write plan. Does not mutate Vercel in any way.
 */
export async function computeSyncDiff(ctx: SyncContext): Promise<SyncDiff> {
  let current: VercelEnvVar[];
  try {
    current = await fetchVercelEnvVars(ctx.vercelToken, ctx.vercelProjectId);
  } catch (err) {
    return {
      results: [],
      summary: emptySummary(),
      error: err instanceof Error ? err.message : String(err),
    };
  }

  // Index the current Vercel state by key for O(1) lookup. If the
  // project has the same key targeted at multiple environments
  // (production/preview/development), we prefer the production
  // record because that's what the koom deploy uses.
  const currentByKey = new Map<string, VercelEnvVar>();
  for (const ev of current) {
    const existing = currentByKey.get(ev.key);
    const isProduction = ev.target.includes("production");
    const existingIsProduction = existing?.target.includes("production");
    if (!existing || (isProduction && !existingIsProduction)) {
      currentByKey.set(ev.key, ev);
    }
  }

  const results: VarSyncResult[] = [];
  const domainCache: { value?: string | null } = {};

  for (const spec of EXPECTED_VARS) {
    const existing = currentByKey.get(spec.key);
    const desired = await resolveDesiredValue(spec.source, ctx, domainCache);

    if (desired.value === null) {
      results.push({
        key: spec.key,
        status: "unresolvable",
        humanSource: spec.humanSource,
        notes: desired.unresolvableReason,
        currentType: existing?.type,
        wouldWrite: false,
      });
      continue;
    }

    if (!existing) {
      results.push({
        key: spec.key,
        status: "missing-on-vercel",
        humanSource: spec.humanSource,
        wouldWrite: true,
      });
      continue;
    }

    // Vercel's `sensitive` type never returns a value field, so we
    // literally cannot compare — report opaque. Sync --write would
    // unconditionally overwrite; we do not know whether that's a
    // real change or a no-op.
    if (existing.type === "sensitive" || existing.value === undefined) {
      results.push({
        key: spec.key,
        status: "opaque",
        humanSource: spec.humanSource,
        currentType: existing.type,
        notes: `Vercel stores this as '${existing.type}' so the current value cannot be read back for comparison.`,
        wouldWrite: true,
      });
      continue;
    }

    if (existing.value === desired.value) {
      results.push({
        key: spec.key,
        status: "in-sync",
        humanSource: spec.humanSource,
        currentType: existing.type,
        wouldWrite: false,
      });
    } else {
      results.push({
        key: spec.key,
        status: "drift",
        humanSource: spec.humanSource,
        currentType: existing.type,
        notes: `Vercel value differs from the desired value computed from ${spec.humanSource}.`,
        wouldWrite: true,
      });
    }
  }

  // Surface any variables on Vercel that koom doesn't know about.
  // These are never touched by --write (sync is additive) but the
  // user should see them in case they're leftover from a previous
  // experiment or an unrelated integration.
  for (const ev of current) {
    if (!EXPECTED_KEY_SET.has(ev.key)) {
      results.push({
        key: ev.key,
        status: "unknown",
        humanSource: "(not expected)",
        currentType: ev.type,
        notes: `Variable exists on Vercel but is not in koom's expected list. Sync --write will not touch it. Delete it manually from the Vercel dashboard if it is stale.`,
        wouldWrite: false,
      });
    }
  }

  const summary = summarize(results);
  return { results, summary };
}

// ────────────────────────────────────────────────────────────────────
// Summarization
// ────────────────────────────────────────────────────────────────────

function emptySummary(): SyncSummary {
  return {
    inSync: 0,
    drift: 0,
    missing: 0,
    opaque: 0,
    unknown: 0,
    unresolvable: 0,
    writesNeeded: 0,
    allInSyncOrOpaque: true,
  };
}

function summarize(results: VarSyncResult[]): SyncSummary {
  const s = emptySummary();
  for (const r of results) {
    switch (r.status) {
      case "in-sync":
        s.inSync++;
        break;
      case "drift":
        s.drift++;
        break;
      case "missing-on-vercel":
        s.missing++;
        break;
      case "opaque":
        s.opaque++;
        break;
      case "unknown":
        s.unknown++;
        break;
      case "unresolvable":
        s.unresolvable++;
        break;
    }
    if (r.wouldWrite) s.writesNeeded++;
  }
  // "All in sync or opaque" is the doctor's pass condition: no
  // detectable drift, no missing vars, no unresolvable vars. Unknown
  // and opaque both count as "not a detectable problem for the
  // doctor" — unknown because sync --write ignores it, opaque
  // because we can't tell either way.
  s.allInSyncOrOpaque =
    s.drift === 0 && s.missing === 0 && s.unresolvable === 0;
  return s;
}
