/**
 * Admin recordings page.
 *
 * Server component: checks the session cookie, redirects to
 * /app/login if not authenticated, then fetches the full list of
 * complete recordings directly from Postgres (no round-trip
 * through the /api/admin/recordings route — that exists for
 * external callers, not for server-side rendering).
 *
 * The actual UI — sort dropdown, delete buttons, first-frame
 * previews, logout — lives in the RecordingsList client component.
 * This page is deliberately tiny: authenticate, fetch, hand off.
 */

import { redirect } from "next/navigation";
import type { ReactElement } from "react";

import { isAdminSessionValid } from "@/lib/auth/session";
import { listAllCompletedRecordings } from "@/lib/db/queries";
import { recordingPublicUrl } from "@/lib/r2/client";

import { RecordingsList, type RecordingListItem } from "./recordings-list";

// Always evaluate on request — we need fresh data and we need to
// re-read the session cookie on every visit.
export const dynamic = "force-dynamic";

export default async function RecordingsPage(): Promise<ReactElement> {
  if (!(await isAdminSessionValid())) {
    redirect("/app/login");
  }

  const recordings = await listAllCompletedRecordings();
  const items: RecordingListItem[] = recordings.map((r) => ({
    recordingId: r.id,
    createdAt: r.createdAt.toISOString(),
    title: r.title,
    originalFilename: r.originalFilename,
    sizeBytes: r.sizeBytes,
    durationSeconds: r.durationSeconds,
    contentType: r.contentType,
    videoUrl: recordingPublicUrl(r.id),
  }));

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-100">
      <RecordingsList initialRecordings={items} />
    </main>
  );
}
