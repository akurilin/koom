/**
 * Pure formatting helpers shared across client and server components.
 *
 * These are intentionally simple — no i18n, no locale negotiation.
 * Good enough for a single-tenant app with an English UI.
 */

export function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

export function formatDuration(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => n.toString().padStart(2, "0");
  if (h > 0) return `${h}:${pad(m)}:${pad(s)}`;
  return `${m}:${pad(s)}`;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024)
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

/**
 * Format a sub-second video timestamp as `m:ss` or `m:ss.t`.
 * Used by the comment system and timeline markers.
 */
export function formatTimestamp(seconds: number): string {
  const clamped = Math.max(0, seconds);
  const whole = Math.floor(clamped);
  const tenths = Math.round((clamped - whole) * 10);
  const m = Math.floor(whole / 60);
  const s = whole % 60;
  const base = `${m}:${s.toString().padStart(2, "0")}`;
  return tenths > 0 ? `${base}.${tenths}` : base;
}
