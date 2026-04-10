/**
 * Public watch page for a single recording.
 *
 * Server component: fetches the recording directly from Postgres
 * (no round-trip through the public API route — that exists for
 * external callers, not for server-side rendering), then renders a
 * minimal dark layout with a video player and basic metadata.
 *
 * Missing or not-yet-complete recordings call notFound() which
 * triggers the sibling not-found.tsx.
 *
 * `?t=<seconds>` deep linking is handled by the sibling client
 * component video-player.tsx — the server component doesn't need to
 * know about the query string.
 */

import Link from "next/link";
import { notFound } from "next/navigation";
import type { ReactElement } from "react";

import { isAdminSessionValid } from "@/lib/auth/session";
import { getCompletedRecordingById } from "@/lib/db/queries";
import { recordingPublicUrl } from "@/lib/r2/client";

import { VideoPlayer } from "./video-player";

interface PageProps {
  params: Promise<{ id: string }>;
}

// Always render on request: we need fresh data and we don't want
// Next.js caching stale metadata or stale share URLs.
export const dynamic = "force-dynamic";

export default async function WatchPage(
  props: PageProps,
): Promise<ReactElement> {
  const { id } = await props.params;

  const recording = await getCompletedRecordingById(id);
  if (!recording) {
    notFound();
  }

  const videoUrl = recordingPublicUrl(recording.id);
  const displayTitle = recording.title ?? recording.originalFilename;
  const showAdminBreadcrumb = await isAdminSessionValid();

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-100 flex flex-col items-center px-4 py-8 sm:py-12">
      <div className="w-full max-w-4xl">
        {showAdminBreadcrumb && (
          <nav
            aria-label="Breadcrumb"
            data-testid="watch-breadcrumb"
            className="mb-4 sm:mb-6"
          >
            <ol className="flex flex-wrap items-center gap-2 text-sm text-zinc-400">
              <li>
                <Link
                  href="/"
                  data-testid="watch-breadcrumb-recordings-link"
                  className="rounded-sm transition hover:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-sky-500/60"
                >
                  My Recordings
                </Link>
              </li>
              <li aria-hidden="true" className="text-zinc-600">
                /
              </li>
              <li
                className="min-w-0 max-w-full truncate text-zinc-200"
                title={displayTitle}
              >
                {displayTitle}
              </li>
            </ol>
          </nav>
        )}

        <VideoPlayer src={videoUrl} contentType={recording.contentType} />

        <div className="mt-6 sm:mt-8">
          <h1 className="text-xl sm:text-2xl font-medium leading-tight break-words">
            {displayTitle}
          </h1>
          <div className="mt-3 text-sm text-zinc-400 flex flex-wrap gap-x-4 gap-y-1">
            <span>{formatDate(recording.createdAt)}</span>
            {recording.durationSeconds !== null && (
              <span>{formatDuration(recording.durationSeconds)}</span>
            )}
            <span>{formatBytes(recording.sizeBytes)}</span>
          </div>
        </div>
      </div>
    </main>
  );
}

/**
 * Format the date in en-US with explicit locale so server-side
 * rendering produces stable output regardless of the host's locale
 * settings. Example: "Apr 8, 2026".
 */
function formatDate(d: Date): string {
  return d.toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

/**
 * Format seconds as m:ss or h:mm:ss. Rounds to the nearest whole
 * second — sub-second precision is noise on a watch page header.
 */
function formatDuration(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => n.toString().padStart(2, "0");
  if (h > 0) return `${h}:${pad(m)}:${pad(s)}`;
  return `${m}:${pad(s)}`;
}

/**
 * Format a byte count as a human-readable string with binary
 * (1024-based) units. One decimal for KB/MB, two for GB — the larger
 * the unit, the more useful an extra digit of precision is.
 */
function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024)
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}
