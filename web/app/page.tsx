/**
 * Canonical admin recordings page.
 *
 * The product only has two real public surfaces:
 *
 *   - `/`      → authenticated recordings list
 *   - `/r/[id]` → public watch page
 *
 * If the visitor is not authenticated, bounce them to `/login`.
 */

import { redirect } from "next/navigation";
import type { ReactElement } from "react";

import { isAdminSessionValid } from "@/lib/auth/session";
import { listAllCompletedRecordings } from "@/lib/db/queries";
import {
  recordingPublicUrl,
  recordingThumbnailPublicUrl,
} from "@/lib/r2/client";

import { RecordingsList, type RecordingListItem } from "./recordings-list";

export const dynamic = "force-dynamic";

export default async function HomePage(): Promise<ReactElement> {
  if (!(await isAdminSessionValid())) {
    redirect("/login");
  }

  // Non-production escape hatch for local development and test
  // environments. Keep the bulk-delete control out of deployed
  // production surfaces.
  const showBulkDelete = process.env.NODE_ENV !== "production";

  const recordings = await listAllCompletedRecordings();
  const items: RecordingListItem[] = recordings.map((r) => ({
    recordingId: r.id,
    createdAt: r.createdAt.toISOString(),
    title: r.title,
    originalFilename: r.originalFilename,
    sizeBytes: r.sizeBytes,
    durationSeconds: r.durationSeconds,
    contentType: r.contentType,
    thumbnailUrl: recordingThumbnailPublicUrl(r.id),
    videoUrl: recordingPublicUrl(r.id),
  }));

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-100">
      <RecordingsList
        initialRecordings={items}
        showBulkDelete={showBulkDelete}
      />
    </main>
  );
}
