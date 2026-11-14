/*
 * scripts/lib/render.ts
 *
 * Read-only helpers for the Render REST API, shared by the doctor
 * (`scripts/doctor.ts`) and the standalone `npm run render:sync`
 * report (`scripts/render-sync.ts`).
 *
 * render.yaml is the source of truth for WHICH variables the web
 * service has; this module answers whether their live VALUES match
 * the local sources of truth in web/.env.local. It never writes to
 * Render: values are entered once when the Blueprint is created and
 * changed afterward in the Render dashboard.
 */

const RENDER_API_BASE = "https://api.render.com/v1";

// ────────────────────────────────────────────────────────────────────
// Expected variable spec
// ────────────────────────────────────────────────────────────────────

/**
 * Where the desired value of a Render env var comes from:
 *
 *   - `env-local`: must equal the same key in web/.env.local.
 *   - `blueprint`: wired up by render.yaml (e.g. `fromDatabase`) with
 *     a value that only exists inside Render, so only its presence
 *     can be verified.
 */
export type VarSource =
  | { kind: "env-local"; envKey: string }
  | { kind: "blueprint"; description: string };

/**
 * Every env var the koom web service needs on Render. Keep in sync
 * with the `envVars` list in render.yaml. Alphabetical for display.
 */
export const EXPECTED_VARS: ReadonlyArray<{ key: string; source: VarSource }> =
  [
    {
      key: "DATABASE_URL",
      source: { kind: "blueprint", description: "render.yaml fromDatabase" },
    },
    {
      key: "KOOM_ADMIN_SECRET",
      source: { kind: "env-local", envKey: "KOOM_ADMIN_SECRET" },
    },
    {
      key: "R2_ACCESS_KEY_ID",
      source: { kind: "env-local", envKey: "R2_ACCESS_KEY_ID" },
    },
    {
      key: "R2_ACCOUNT_ID",
      source: { kind: "env-local", envKey: "R2_ACCOUNT_ID" },
    },
    { key: "R2_BUCKET", source: { kind: "env-local", envKey: "R2_BUCKET" } },
    {
      key: "R2_PUBLIC_BASE_URL",
      source: { kind: "env-local", envKey: "R2_PUBLIC_BASE_URL" },
    },
    {
      key: "R2_SECRET_ACCESS_KEY",
      source: { kind: "env-local", envKey: "R2_SECRET_ACCESS_KEY" },
    },
  ];

export function humanSource(source: VarSource): string {
  return source.kind === "env-local" ? "web/.env.local" : source.description;
}

// ────────────────────────────────────────────────────────────────────
// API access
// ────────────────────────────────────────────────────────────────────

export class RenderApiError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message);
  }
}

async function renderGet<T>(apiKey: string, path: string): Promise<T> {
  const url = `${RENDER_API_BASE}${path}`;
  let res: Response;
  try {
    res = await fetch(url, {
      headers: {
        Authorization: `Bearer ${apiKey}`,
        Accept: "application/json",
      },
      signal: AbortSignal.timeout(10_000),
    });
  } catch (err) {
    throw new RenderApiError(
      `Could not reach ${url}: ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  if (res.status === 401) {
    throw new RenderApiError(
      "HTTP 401 from the Render API: RENDER_API_KEY is missing or invalid. Create a key at Render dashboard → Account Settings → API Keys.",
      401,
    );
  }
  if (res.status === 403) {
    throw new RenderApiError(
      "HTTP 403 from the Render API: RENDER_API_KEY cannot access this resource. Use a key from the workspace that owns the koom Blueprint.",
      403,
    );
  }
  if (res.status === 404) {
    throw new RenderApiError(
      `HTTP 404 for ${path}. Check RENDER_SERVICE_ID in web/.env.prod.local — it is the 'srv-...' id in the koom-web service URL, not the service name.`,
      404,
    );
  }
  if (!res.ok) {
    throw new RenderApiError(`HTTP ${res.status} from ${url}`, res.status);
  }
  return (await res.json()) as T;
}

export interface RenderService {
  id: string;
  name: string;
  suspended?: string;
  serviceDetails?: {
    /** Public onrender.com URL for web services, e.g. https://koom-web.onrender.com */
    url?: string;
  };
}

export function fetchService(
  apiKey: string,
  serviceId: string,
): Promise<RenderService> {
  return renderGet<RenderService>(
    apiKey,
    `/services/${encodeURIComponent(serviceId)}`,
  );
}

/** All env vars set directly on the service, keyed by name. */
export async function fetchServiceEnvVars(
  apiKey: string,
  serviceId: string,
): Promise<Map<string, string>> {
  const vars = new Map<string, string>();
  let cursor: string | undefined;
  // Cursor pagination: keep requesting pages of 100 until a short page.
  for (;;) {
    const query = new URLSearchParams({ limit: "100" });
    if (cursor) query.set("cursor", cursor);
    const page = await renderGet<
      Array<{ envVar: { key: string; value: string }; cursor: string }>
    >(
      apiKey,
      `/services/${encodeURIComponent(serviceId)}/env-vars?${query.toString()}`,
    );
    for (const item of page) vars.set(item.envVar.key, item.envVar.value);
    if (page.length < 100) return vars;
    cursor = page[page.length - 1]!.cursor;
  }
}

// ────────────────────────────────────────────────────────────────────
// Comparison
// ────────────────────────────────────────────────────────────────────

export type VarStatus =
  | "in-sync"
  | "drift"
  | "missing-on-render"
  | "unresolvable";

export interface VarSyncResult {
  key: string;
  status: VarStatus;
  humanSource: string;
  notes?: string;
}

export interface EnvDiff {
  results: VarSyncResult[];
  /** Variables on Render that koom doesn't manage (ignored). */
  unknownKeys: string[];
}

/**
 * Compare the live env vars on the Render service with EXPECTED_VARS.
 * Values are never included in the results, so the output is safe to
 * print.
 */
export async function computeEnvDiff(options: {
  apiKey: string;
  serviceId: string;
  localEnv: Record<string, string>;
}): Promise<EnvDiff> {
  const live = await fetchServiceEnvVars(options.apiKey, options.serviceId);

  const results = EXPECTED_VARS.map(({ key, source }): VarSyncResult => {
    const base = { key, humanSource: humanSource(source) };
    const liveValue = live.get(key);

    if (source.kind === "blueprint") {
      return liveValue
        ? { ...base, status: "in-sync" }
        : {
            ...base,
            status: "missing-on-render",
            notes: "Re-sync the Blueprint in the Render dashboard.",
          };
    }

    const desired = options.localEnv[source.envKey];
    if (!desired) {
      return {
        ...base,
        status: "unresolvable",
        notes: `${source.envKey} is not set in web/.env.local`,
      };
    }
    if (liveValue === undefined) {
      return { ...base, status: "missing-on-render" };
    }
    return liveValue === desired
      ? { ...base, status: "in-sync" }
      : {
          ...base,
          status: "drift",
          notes: "Render value differs from web/.env.local",
        };
  });

  const expected = new Set(EXPECTED_VARS.map((v) => v.key));
  const unknownKeys = [...live.keys()].filter((k) => !expected.has(k)).sort();

  return { results, unknownKeys };
}
