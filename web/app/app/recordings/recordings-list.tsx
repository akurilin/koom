/**
 * Interactive admin recordings list.
 *
 * Renders a grid of recording cards with first-frame video
 * previews, a sort dropdown, a delete button per card, and a
 * logout button.
 *
 * The first-frame preview trick: append `#t=0.1` to the video URL
 * and set `preload="metadata"`. The browser only downloads the
 * moov atom (file header) to render a seek-frame thumbnail at the
 * 100 ms mark. Because our recordings are produced with
 * `+faststart`, the moov lives at the start of the file and the
 * metadata fetch is small regardless of total file size. No
 * server-side thumbnail generation needed.
 *
 * Sort is done entirely client-side. At single-tenant scale the
 * full list fits in memory comfortably; we'd add server-side
 * pagination only if koom ever had thousands of recordings per
 * user.
 *
 * Delete uses `window.confirm` for now — that's the minimum viable
 * "are you sure" gate. Can dress it up with a real modal later.
 *
 * Every interactive element has a `data-testid` attribute so the
 * Playwright E2E test can target them without depending on
 * styles or DOM structure.
 */

"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";

export interface RecordingListItem {
  recordingId: string;
  createdAt: string;
  title: string | null;
  originalFilename: string;
  sizeBytes: number;
  durationSeconds: number | null;
  contentType: string;
  videoUrl: string;
}

type SortKey =
  | "date-desc"
  | "date-asc"
  | "name-asc"
  | "name-desc"
  | "size-desc"
  | "size-asc";

const SORT_OPTIONS: Array<{ value: SortKey; label: string }> = [
  { value: "date-desc", label: "Newest first" },
  { value: "date-asc", label: "Oldest first" },
  { value: "name-asc", label: "Name A → Z" },
  { value: "name-desc", label: "Name Z → A" },
  { value: "size-desc", label: "Largest first" },
  { value: "size-asc", label: "Smallest first" },
];

interface Props {
  initialRecordings: RecordingListItem[];
}

export function RecordingsList({ initialRecordings }: Props) {
  const router = useRouter();
  const [recordings, setRecordings] = useState(initialRecordings);
  const [sortKey, setSortKey] = useState<SortKey>("date-desc");
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const sorted = useMemo(
    () => sortRecordings(recordings, sortKey),
    [recordings, sortKey],
  );

  async function handleDelete(recordingId: string, filename: string) {
    const confirmed = window.confirm(
      `Delete "${filename}"? This permanently removes the video from R2 and the database.`,
    );
    if (!confirmed) return;

    setErrorMessage(null);
    setDeletingId(recordingId);
    try {
      const res = await fetch(`/api/admin/recordings/${recordingId}`, {
        method: "DELETE",
      });
      if (!res.ok) {
        const body = (await res.json().catch(() => ({}))) as {
          error?: string;
        };
        setErrorMessage(body.error ?? `Delete failed (HTTP ${res.status})`);
        return;
      }
      // Remove from local state so the card disappears immediately.
      setRecordings((prev) =>
        prev.filter((r) => r.recordingId !== recordingId),
      );
    } catch (err) {
      setErrorMessage(err instanceof Error ? err.message : "Delete failed");
    } finally {
      setDeletingId(null);
    }
  }

  async function handleLogout() {
    try {
      await fetch("/api/admin/session", { method: "DELETE" });
    } catch {
      // Swallow — we're about to redirect anyway.
    }
    router.replace("/app/login");
    router.refresh();
  }

  return (
    <div className="mx-auto max-w-6xl px-4 py-8 sm:py-12">
      <header
        className="mb-8 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between"
        data-testid="recordings-header"
      >
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">
            My Recordings
          </h1>
          <p className="mt-1 text-sm text-zinc-400">
            {recordings.length}{" "}
            {recordings.length === 1 ? "recording" : "recordings"}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <label htmlFor="sort-select" className="text-sm text-zinc-400">
            Sort by
          </label>
          <select
            id="sort-select"
            data-testid="sort-select"
            value={sortKey}
            onChange={(e) => setSortKey(e.target.value as SortKey)}
            className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm text-zinc-100 focus:border-sky-500 focus:outline-none focus:ring-2 focus:ring-sky-500/40"
          >
            {SORT_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </select>
          <button
            type="button"
            data-testid="logout-button"
            onClick={handleLogout}
            className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm text-zinc-300 hover:border-zinc-500 hover:text-zinc-100"
          >
            Log out
          </button>
        </div>
      </header>

      {errorMessage && (
        <div
          className="mb-6 rounded-md border border-red-800/60 bg-red-950/40 px-4 py-3 text-sm text-red-300"
          data-testid="error-banner"
          role="alert"
        >
          {errorMessage}
        </div>
      )}

      {sorted.length === 0 ? (
        <div
          className="rounded-md border border-zinc-800 bg-zinc-900/40 px-6 py-12 text-center text-sm text-zinc-400"
          data-testid="empty-state"
        >
          No recordings yet. Record something in the desktop app and it&apos;ll
          show up here.
        </div>
      ) : (
        <div
          className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3"
          data-testid="recordings-grid"
        >
          {sorted.map((recording) => (
            <RecordingCard
              key={recording.recordingId}
              recording={recording}
              isDeleting={deletingId === recording.recordingId}
              onDelete={() =>
                handleDelete(recording.recordingId, recording.originalFilename)
              }
            />
          ))}
        </div>
      )}
    </div>
  );
}

interface CardProps {
  recording: RecordingListItem;
  isDeleting: boolean;
  onDelete: () => void;
}

function RecordingCard({ recording, isDeleting, onDelete }: CardProps) {
  // Append #t=0.1 to force the <video> element to seek to the
  // 100 ms mark and render the first frame instead of a black
  // square. preload="metadata" downloads just the moov atom so
  // this is cheap.
  const previewSrc = `${recording.videoUrl}#t=0.1`;
  const watchHref = `/r/${recording.recordingId}`;
  const displayTitle = recording.title ?? recording.originalFilename;

  return (
    <div
      data-testid="recording-card"
      data-recording-id={recording.recordingId}
      className="group overflow-hidden rounded-lg border border-zinc-800 bg-zinc-900/50 transition hover:border-zinc-700"
    >
      <Link
        href={watchHref}
        data-testid="watch-link"
        className="block bg-black"
        aria-label={`Watch ${displayTitle}`}
      >
        <video
          src={previewSrc}
          preload="metadata"
          muted
          playsInline
          className="aspect-video w-full object-cover"
        >
          <p className="p-4 text-xs text-zinc-400">
            Your browser cannot play this {recording.contentType} file.
          </p>
        </video>
      </Link>

      <div className="px-4 py-3">
        <h2
          className="truncate text-sm font-medium"
          data-testid="filename"
          title={displayTitle}
        >
          {displayTitle}
        </h2>
        <div className="mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-zinc-400">
          <span data-testid="card-date">{formatDate(recording.createdAt)}</span>
          <span data-testid="card-size">
            {formatBytes(recording.sizeBytes)}
          </span>
          {recording.durationSeconds !== null && (
            <span data-testid="card-duration">
              {formatDuration(recording.durationSeconds)}
            </span>
          )}
        </div>
      </div>

      <div className="flex items-center justify-between border-t border-zinc-800 px-4 py-2">
        <Link
          href={watchHref}
          className="text-xs text-sky-400 hover:text-sky-300"
        >
          Watch →
        </Link>
        <button
          type="button"
          data-testid="delete-button"
          onClick={onDelete}
          disabled={isDeleting}
          className="rounded border border-red-900/60 px-2 py-1 text-xs text-red-400 hover:border-red-700 hover:text-red-300 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {isDeleting ? "Deleting…" : "Delete"}
        </button>
      </div>
    </div>
  );
}

// ────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────

function sortRecordings(
  recordings: RecordingListItem[],
  key: SortKey,
): RecordingListItem[] {
  const copy = [...recordings];
  switch (key) {
    case "date-desc":
      return copy.sort(
        (a, b) =>
          new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime(),
      );
    case "date-asc":
      return copy.sort(
        (a, b) =>
          new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime(),
      );
    case "name-asc":
      return copy.sort((a, b) =>
        a.originalFilename.localeCompare(b.originalFilename),
      );
    case "name-desc":
      return copy.sort((a, b) =>
        b.originalFilename.localeCompare(a.originalFilename),
      );
    case "size-desc":
      return copy.sort((a, b) => b.sizeBytes - a.sizeBytes);
    case "size-asc":
      return copy.sort((a, b) => a.sizeBytes - b.sizeBytes);
  }
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

function formatDuration(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => n.toString().padStart(2, "0");
  if (h > 0) return `${h}:${pad(m)}:${pad(s)}`;
  return `${m}:${pad(s)}`;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024)
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}
