/**
 * Public watch page for a single recording.
 *
 * Server component: fetches the recording and its comments directly
 * from Postgres, checks admin status, then renders the
 * WatchExperience client component which orchestrates the player,
 * timeline markers, and comments pane.
 *
 * Missing or not-yet-complete recordings call notFound() which
 * triggers the sibling not-found.tsx.
 */

import Link from "next/link";
import { notFound } from "next/navigation";
import { cookies } from "next/headers";
import type { ReactElement } from "react";

import { isAdminSessionValid } from "@/lib/auth/session";
import {
  listCommentsByRecording,
  getOrCreateCommenter,
} from "@/lib/db/comments";
import { getCompletedRecordingById } from "@/lib/db/queries";
import { recordingPublicUrl } from "@/lib/r2/client";

import { WatchExperience } from "./watch-experience";
import type { CommentData, MeData } from "./comments-pane";

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

  // Check admin status — used for breadcrumb and comments pane
  const isAdmin = await isAdminSessionValid();

  // Read commenter cookie for isOwn flags
  const cookieStore = await cookies();
  const commenterCookie = cookieStore.get("koom-commenter");
  const commenterId = commenterCookie?.value ?? null;

  // Ensure commenter row exists (same logic as the GET endpoint)
  if (commenterId) {
    try {
      await getOrCreateCommenter(commenterId);
    } catch {
      // Non-fatal
    }
  }

  // Fetch comments server-side for the initial render
  const rawComments = await listCommentsByRecording(id);
  const initialComments: CommentData[] = rawComments.map((c) => ({
    id: c.id,
    displayName: c.displayName,
    body: c.body,
    timestampSeconds: c.timestampSeconds,
    createdAt: c.createdAt.toISOString(),
    isAdmin: c.isAdmin,
    isOwn: c.isAdmin ? isAdmin : c.commenterId === commenterId,
  }));

  const me: MeData | null =
    commenterId || isAdmin
      ? {
          kind: isAdmin ? "admin" : "anonymous",
          displayName: isAdmin
            ? "Admin"
            : `Guest ${(commenterId ?? "").slice(0, 4)}`,
          commenterId: isAdmin ? null : commenterId,
          canDelete: isAdmin,
        }
      : null;

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-100 px-4 py-8 sm:py-12">
      <div className="w-full max-w-6xl mx-auto">
        {isAdmin && (
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

        <WatchExperience
          recordingId={recording.id}
          videoUrl={videoUrl}
          contentType={recording.contentType}
          displayTitle={displayTitle}
          createdAt={recording.createdAt.toISOString()}
          durationSeconds={recording.durationSeconds}
          sizeBytes={recording.sizeBytes}
          initialComments={initialComments}
          initialMe={me}
        />
      </div>
    </main>
  );
}
