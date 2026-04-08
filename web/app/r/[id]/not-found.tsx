/**
 * Custom 404 boundary for the /r/[id] segment.
 *
 * Next.js renders this when the watch page calls notFound(), which
 * happens when:
 *
 *   - The recording id does not exist in the database at all.
 *   - The recording exists but has `status = 'pending'` — we
 *     intentionally hide mid-upload rows from the public view.
 *
 * Both cases render the same message to avoid leaking whether a
 * given id maps to an in-progress upload.
 */

import Link from "next/link";
import type { ReactElement } from "react";

export default function RecordingNotFound(): ReactElement {
  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-100 flex flex-col items-center justify-center px-4">
      <div className="max-w-md text-center">
        <h1 className="text-3xl font-medium mb-3">Recording not found</h1>
        <p className="text-zinc-400 mb-8 text-sm">
          The recording you&apos;re looking for doesn&apos;t exist, was removed,
          or isn&apos;t ready to watch yet.
        </p>
        <Link
          href="/"
          className="inline-block text-sm text-sky-400 hover:text-sky-300 underline underline-offset-4"
        >
          Back to home
        </Link>
      </div>
    </main>
  );
}
