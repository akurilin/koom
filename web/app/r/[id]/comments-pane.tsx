/**
 * Right-pane comment list and compose form.
 *
 * Displays all comments for the recording sorted by timestamp,
 * lets the viewer post new comments, and delete their own (or
 * any comment if admin).
 */

"use client";

import { useCallback, useRef, useState } from "react";

import { formatTimestamp } from "@/lib/format";
import type { CommentData, MeData } from "@/lib/types";

export type { CommentData, MeData };

interface CommentsPaneProps {
  recordingId: string;
  comments: CommentData[];
  me: MeData | null;
  highlightedCommentId: string | null;
  currentTime: number;
  onCommentCreated: (comment: CommentData) => void;
  onCommentDeleted: (commentId: string) => void;
  onCommentClick: (commentId: string, timestampSeconds: number) => void;
}

export function CommentsPane({
  recordingId,
  comments,
  me,
  highlightedCommentId,
  currentTime,
  onCommentCreated,
  onCommentDeleted,
  onCommentClick,
}: CommentsPaneProps) {
  const [body, setBody] = useState("");
  const [timestamp, setTimestamp] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const bodyRef = useRef<HTMLTextAreaElement>(null);

  const isAdmin = me?.kind === "admin";

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      setError(null);

      const trimmedBody = body.trim();
      if (!trimmedBody) return;

      const ts =
        timestamp === ""
          ? Math.round(currentTime * 10) / 10
          : Number(timestamp);
      if (!Number.isFinite(ts) || ts < 0) {
        setError("Invalid timestamp");
        return;
      }

      setSubmitting(true);
      try {
        const res = await fetch(
          `/api/public/recordings/${recordingId}/comments`,
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              body: trimmedBody,
              timestampSeconds: ts,
            }),
          },
        );

        if (!res.ok) {
          const errBody = await res.json().catch(() => ({}));
          setError(
            (errBody as { error?: string }).error ?? `Error ${res.status}`,
          );
          return;
        }

        const { comment } = (await res.json()) as { comment: CommentData };
        onCommentCreated(comment);
        setBody("");
        setTimestamp("");
        bodyRef.current?.focus();
      } catch {
        setError("Network error");
      } finally {
        setSubmitting(false);
      }
    },
    [body, timestamp, currentTime, recordingId, onCommentCreated],
  );

  const handleDelete = useCallback(
    async (commentId: string) => {
      if (!confirm("Delete this comment?")) return;

      try {
        const res = await fetch(
          `/api/public/recordings/${recordingId}/comments/${commentId}`,
          { method: "DELETE" },
        );
        if (res.ok) {
          onCommentDeleted(commentId);
        }
      } catch {
        // Silently fail — the comment stays visible.
      }
    },
    [recordingId, onCommentDeleted],
  );

  return (
    <div data-testid="comments-pane" className="flex flex-col h-full">
      {/* Header */}
      <div className="px-4 py-3 border-b border-zinc-800">
        <h2 className="text-sm font-medium text-zinc-300">
          Comments ({comments.length})
        </h2>
      </div>

      {/* Comment list */}
      <div className="flex-1 overflow-y-auto px-4 py-3 space-y-3">
        {comments.length === 0 ? (
          <p
            data-testid="no-comments-message"
            className="text-sm text-zinc-500 text-center py-8"
          >
            No comments yet
          </p>
        ) : (
          comments.map((c) => (
            <CommentItem
              key={c.id}
              comment={c}
              isHighlighted={c.id === highlightedCommentId}
              canDelete={c.isOwn || isAdmin}
              onTimestampClick={() => onCommentClick(c.id, c.timestampSeconds)}
              onDelete={() => handleDelete(c.id)}
            />
          ))
        )}
      </div>

      {/* Compose form */}
      <form
        onSubmit={handleSubmit}
        className="border-t border-zinc-800 px-4 py-3 space-y-2"
      >
        <textarea
          ref={bodyRef}
          data-testid="comment-body-input"
          value={body}
          onChange={(e) => setBody(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              e.currentTarget.form?.requestSubmit();
            }
          }}
          maxLength={2000}
          rows={2}
          placeholder="Add a comment..."
          className="w-full bg-zinc-800 text-zinc-100 text-sm rounded-md px-3 py-2 placeholder:text-zinc-500 resize-none focus:outline-none focus:ring-1 focus:ring-sky-500"
        />
        <div className="flex items-center gap-2">
          <label className="flex items-center gap-1.5 text-xs text-zinc-400">
            <span>at</span>
            <input
              data-testid="comment-timestamp-input"
              type="number"
              min="0"
              step="0.1"
              value={timestamp}
              onChange={(e) => setTimestamp(e.target.value)}
              placeholder={String(Math.round(currentTime * 10) / 10)}
              className="w-16 bg-zinc-800 text-zinc-100 text-xs rounded px-2 py-1 focus:outline-none focus:ring-1 focus:ring-sky-500 [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
            />
            <span>sec</span>
          </label>
          <div className="flex-1" />
          <button
            data-testid="submit-comment-button"
            type="submit"
            disabled={submitting || body.trim().length === 0 || !me}
            className="text-xs font-medium px-3 py-1.5 rounded-md bg-sky-600 hover:bg-sky-500 disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
          >
            {submitting ? "Posting..." : "Post"}
          </button>
        </div>
        {error && <p className="text-xs text-red-400">{error}</p>}
      </form>
    </div>
  );
}

// ────────────────────────────────────────────────────────────────
// Individual comment item
// ────────────────────────────────────────────────────────────────

function CommentItem({
  comment,
  isHighlighted,
  canDelete,
  onTimestampClick,
  onDelete,
}: {
  comment: CommentData;
  isHighlighted: boolean;
  canDelete: boolean;
  onTimestampClick: () => void;
  onDelete: () => void;
}) {
  return (
    <div
      data-testid="comment-item"
      className={`group rounded-md px-3 py-2 text-sm transition-colors ${
        isHighlighted
          ? "bg-sky-950/50 ring-1 ring-sky-700"
          : "hover:bg-zinc-800/50"
      }`}
    >
      <div className="flex items-center gap-2 mb-1">
        {/* Avatar dot */}
        <span
          className={`inline-block w-5 h-5 rounded-full text-[10px] font-bold flex items-center justify-center shrink-0 ${
            comment.isAdmin
              ? "bg-sky-600 text-white"
              : `bg-zinc-700 text-zinc-300`
          }`}
        >
          {comment.isAdmin
            ? "A"
            : (comment.displayName.charAt(6)?.toUpperCase() ?? "?")}
        </span>

        {/* Display name */}
        <span className="font-medium text-zinc-200 truncate text-xs">
          {comment.displayName}
        </span>

        {comment.isAdmin && (
          <span
            data-testid="admin-badge"
            className="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-sky-600/20 text-sky-400"
          >
            Admin
          </span>
        )}

        {/* Timestamp chip */}
        <button
          data-testid="comment-timestamp"
          type="button"
          onClick={onTimestampClick}
          className="text-[10px] text-sky-400 hover:text-sky-300 font-mono ml-auto"
        >
          {formatTimestamp(comment.timestampSeconds)}
        </button>

        {/* Delete button */}
        {canDelete && (
          <button
            data-testid="delete-comment-button"
            type="button"
            onClick={onDelete}
            className="text-zinc-600 hover:text-red-400 opacity-0 group-hover:opacity-100 transition-opacity text-xs"
            title="Delete comment"
          >
            &times;
          </button>
        )}
      </div>

      <p className="text-zinc-300 text-xs leading-relaxed whitespace-pre-wrap break-words">
        {comment.body}
      </p>
    </div>
  );
}
