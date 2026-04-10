/**
 * Shared API / UI data shapes.
 *
 * These interfaces define the JSON-friendly projections of database
 * models used by both server components and API route responses.
 * Keeping them here (rather than in client components) ensures the
 * SSR and API serialization paths stay in sync.
 */

import type { Comment } from "./db/comments";
import type { Recording } from "./db/queries";
import { recordingPublicUrl, recordingThumbnailPublicUrl } from "./r2/client";

// ────────────────────────────────────────────────────────────────
// Comment types
// ────────────────────────────────────────────────────────────────

export interface CommentData {
  id: string;
  displayName: string;
  body: string;
  timestampSeconds: number;
  createdAt: string;
  isAdmin: boolean;
  isOwn: boolean;
}

export interface MeData {
  kind: "admin" | "anonymous" | "guest";
  displayName: string;
  commenterId: string | null;
  canDelete: boolean;
}

/**
 * Serialize a database Comment into the API/UI shape. The caller
 * provides the viewer context so `isOwn` can be computed.
 */
export function serializeComment(
  comment: Comment,
  viewer: { isAdmin: boolean; commenterId: string | null },
): CommentData {
  return {
    id: comment.id,
    displayName: comment.displayName,
    body: comment.body,
    timestampSeconds: comment.timestampSeconds,
    createdAt: comment.createdAt.toISOString(),
    isAdmin: comment.isAdmin,
    isOwn: comment.isAdmin
      ? viewer.isAdmin
      : comment.commenterId === viewer.commenterId,
  };
}

/**
 * Build the MeData payload for a viewer. Returns null if the
 * viewer has no identity (no cookie, not admin).
 */
export function buildMePayload(viewer: {
  isAdmin: boolean;
  commenterId: string | null;
}): MeData | null {
  if (!viewer.commenterId && !viewer.isAdmin) return null;
  return {
    kind: viewer.isAdmin ? "admin" : "anonymous",
    displayName: viewer.isAdmin
      ? "Admin"
      : `Guest ${(viewer.commenterId ?? "").slice(0, 4)}`,
    commenterId: viewer.isAdmin ? null : viewer.commenterId,
    canDelete: viewer.isAdmin,
  };
}

// ────────────────────────────────────────────────────────────────
// Recording types
// ────────────────────────────────────────────────────────────────

export interface RecordingListItem {
  recordingId: string;
  createdAt: string;
  title: string | null;
  originalFilename: string;
  sizeBytes: number;
  durationSeconds: number | null;
  contentType: string;
  thumbnailUrl: string;
  videoUrl: string;
}

/**
 * Project a database Recording into the JSON-friendly list item
 * shape, including fully-qualified R2 URLs.
 */
export function toRecordingListItem(r: Recording): RecordingListItem {
  return {
    recordingId: r.id,
    createdAt: r.createdAt.toISOString(),
    title: r.title,
    originalFilename: r.originalFilename,
    sizeBytes: r.sizeBytes,
    durationSeconds: r.durationSeconds,
    contentType: r.contentType,
    thumbnailUrl: recordingThumbnailPublicUrl(r.id),
    videoUrl: recordingPublicUrl(r.id),
  };
}
