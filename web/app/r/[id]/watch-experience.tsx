/**
 * Client component that orchestrates the video player, timeline
 * markers, and the tabbed right rail (comments / transcript).
 * Owns the shared state between them (comments list, highlighted
 * comment, video ref for seeking, active tab).
 *
 * Receives initial data from the server component (page.tsx)
 * so the first paint already has comments — no loading spinner.
 */

"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import { formatBytes, formatDate, formatDuration } from "@/lib/format";

import { CommentsPane, type CommentData, type MeData } from "./comments-pane";
import { TimelineMarkers } from "./timeline-markers";
import { TranscriptPane } from "./transcript-pane";
import { VideoPlayer } from "./video-player";

type RailTab = "comments" | "transcript";

interface WatchExperienceProps {
  recordingId: string;
  videoUrl: string;
  transcriptUrl: string;
  contentType: string;
  displayTitle: string;
  originalFilename: string;
  isAdmin: boolean;
  createdAt: string;
  durationSeconds: number | null;
  sizeBytes: number;
  initialComments: CommentData[];
  initialMe: MeData | null;
}

export function WatchExperience({
  recordingId,
  videoUrl,
  transcriptUrl,
  contentType,
  displayTitle,
  originalFilename,
  isAdmin,
  createdAt,
  durationSeconds,
  sizeBytes,
  initialComments,
  initialMe,
}: WatchExperienceProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [comments, setComments] = useState<CommentData[]>(initialComments);
  const [me, setMe] = useState<MeData | null>(initialMe);
  const [highlightedCommentId, setHighlightedCommentId] = useState<
    string | null
  >(null);
  const [currentTime, setCurrentTime] = useState(0);
  const [activeTab, setActiveTab] = useState<RailTab>("transcript");
  const [railOpen, setRailOpen] = useState(true);

  // Inline title editing (admin only)
  const [title, setTitle] = useState(displayTitle);
  const [isEditingTitle, setIsEditingTitle] = useState(false);
  const [draftTitle, setDraftTitle] = useState(displayTitle);
  const [isSavingTitle, setIsSavingTitle] = useState(false);
  const titleInputRef = useRef<HTMLInputElement>(null);

  const startEditing = useCallback(() => {
    if (!isAdmin) return;
    setDraftTitle(title);
    setIsEditingTitle(true);
  }, [isAdmin, title]);

  useEffect(() => {
    if (isEditingTitle && titleInputRef.current) {
      titleInputRef.current.focus();
      titleInputRef.current.select();
    }
  }, [isEditingTitle]);

  const cancelEditing = useCallback(() => {
    setIsEditingTitle(false);
    setDraftTitle(title);
  }, [title]);

  const saveTitle = useCallback(async () => {
    const trimmed = draftTitle.trim();
    const newTitle = trimmed === "" ? null : trimmed;
    const newDisplay = newTitle ?? originalFilename;

    // No change — just close the editor.
    if (newDisplay === title) {
      setIsEditingTitle(false);
      return;
    }

    setIsSavingTitle(true);
    try {
      const res = await fetch(`/api/admin/recordings/${recordingId}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title: newTitle }),
      });
      if (res.ok) {
        setTitle(newDisplay);
        setIsEditingTitle(false);
      }
    } finally {
      setIsSavingTitle(false);
    }
  }, [draftTitle, originalFilename, title, recordingId]);

  const handleTitleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLInputElement>) => {
      if (e.key === "Enter") {
        e.preventDefault();
        saveTitle();
      } else if (e.key === "Escape") {
        e.preventDefault();
        cancelEditing();
      }
    },
    [saveTitle, cancelEditing],
  );

  // On mount, call the GET comments endpoint to ensure the
  // koom-commenter cookie is set via the Set-Cookie header.
  // Server components cannot set cookies — only route handlers
  // can — so this client-side fetch is the identity-establishment
  // mechanism. It also refreshes the comments list and me payload.
  useEffect(() => {
    let cancelled = false;
    fetch(`/api/public/recordings/${recordingId}/comments`)
      .then((res) => (res.ok ? res.json() : null))
      .then((data: { comments: CommentData[]; me: MeData } | null) => {
        if (cancelled || !data) return;
        setComments(data.comments);
        setMe(data.me);
      })
      .catch(() => {
        // Non-fatal — we still have the SSR data.
      });
    return () => {
      cancelled = true;
    };
  }, [recordingId]);

  const handleCommentCreated = useCallback((comment: CommentData) => {
    setComments((prev) => {
      const next = [...prev, comment];
      next.sort((a, b) => a.timestampSeconds - b.timestampSeconds);
      return next;
    });
  }, []);

  const handleCommentDeleted = useCallback((commentId: string) => {
    setComments((prev) => prev.filter((c) => c.id !== commentId));
    setHighlightedCommentId((prev) => (prev === commentId ? null : prev));
  }, []);

  const seekAndHighlight = useCallback(
    (commentId: string, timestampSeconds: number) => {
      const video = videoRef.current;
      if (video) {
        video.currentTime = timestampSeconds;
      }
      setHighlightedCommentId(commentId);
    },
    [],
  );

  const handleTimeUpdate = useCallback((time: number) => {
    setCurrentTime(time);
  }, []);

  const seekTo = useCallback((seconds: number) => {
    const video = videoRef.current;
    if (video) {
      video.currentTime = seconds;
    }
  }, []);

  return (
    <div className="w-full flex flex-col lg:flex-row gap-4">
      {/* Left column: video + metadata */}
      <div className="flex-1 min-w-0">
        <VideoPlayer
          src={videoUrl}
          contentType={contentType}
          videoRef={videoRef}
          onTimeUpdate={handleTimeUpdate}
        />
        <TimelineMarkers
          comments={comments}
          durationSeconds={durationSeconds}
          onMarkerClick={seekAndHighlight}
        />
        <div className="mt-4 sm:mt-6">
          {isEditingTitle ? (
            <div className="flex items-center gap-2">
              <input
                ref={titleInputRef}
                type="text"
                value={draftTitle}
                onChange={(e) => setDraftTitle(e.target.value)}
                onKeyDown={handleTitleKeyDown}
                onBlur={cancelEditing}
                disabled={isSavingTitle}
                maxLength={200}
                className="flex-1 min-w-0 text-xl sm:text-2xl font-medium leading-tight bg-zinc-50 dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 border border-zinc-300 dark:border-zinc-700 rounded-md px-3 py-1.5 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500 disabled:opacity-50"
              />
              <button
                type="button"
                onMouseDown={(e) => e.preventDefault()}
                onClick={saveTitle}
                disabled={isSavingTitle}
                className="shrink-0 p-1.5 rounded-md text-zinc-500 dark:text-zinc-400 hover:text-emerald-500 dark:hover:text-emerald-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition disabled:opacity-50"
                aria-label="Save title"
              >
                <svg
                  width="18"
                  height="18"
                  viewBox="0 0 18 18"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                >
                  <polyline points="3.5 9.5 7 13 14.5 5.5" />
                </svg>
              </button>
              <button
                type="button"
                onMouseDown={(e) => e.preventDefault()}
                onClick={cancelEditing}
                disabled={isSavingTitle}
                className="shrink-0 p-1.5 rounded-md text-zinc-500 dark:text-zinc-400 hover:text-red-500 dark:hover:text-red-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition disabled:opacity-50"
                aria-label="Cancel rename"
              >
                <svg
                  width="18"
                  height="18"
                  viewBox="0 0 18 18"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                >
                  <line x1="5" y1="5" x2="13" y2="13" />
                  <line x1="13" y1="5" x2="5" y2="13" />
                </svg>
              </button>
            </div>
          ) : (
            <h1
              className={`text-xl sm:text-2xl font-medium leading-tight break-words${isAdmin ? " cursor-pointer rounded-md transition hover:bg-zinc-100 dark:hover:bg-zinc-800/60 -mx-2 px-2 py-1" : ""}`}
              onClick={isAdmin ? startEditing : undefined}
              title={isAdmin ? "Click to rename" : undefined}
            >
              {title}
            </h1>
          )}
          <div className="mt-3 text-sm text-zinc-500 dark:text-zinc-400 flex flex-wrap gap-x-4 gap-y-1">
            <span>{formatDate(createdAt)}</span>
            {durationSeconds !== null && (
              <span>{formatDuration(durationSeconds)}</span>
            )}
            <span>{formatBytes(sizeBytes)}</span>
          </div>
        </div>
      </div>

      {/* Right rail: tabbed comments / transcript (collapsible) */}
      {railOpen ? (
        <div className="w-full lg:w-[400px] lg:shrink-0 lg:sticky lg:top-4 lg:max-h-[calc(100vh-2rem)] bg-zinc-50 dark:bg-zinc-900/50 rounded-lg border border-zinc-200 dark:border-zinc-800 overflow-hidden flex flex-col max-h-[600px] lg:max-h-[calc(100vh-2rem)]">
          {/* Tab bar */}
          <div className="flex border-b border-zinc-200 dark:border-zinc-800">
            <button
              type="button"
              onClick={() => setActiveTab("transcript")}
              className={`flex-1 px-4 py-2.5 text-sm font-medium transition-colors ${
                activeTab === "transcript"
                  ? "text-zinc-900 dark:text-zinc-100 border-b-2 border-sky-500"
                  : "text-zinc-400 dark:text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
              }`}
            >
              Transcript
            </button>
            <button
              type="button"
              onClick={() => setActiveTab("comments")}
              className={`flex-1 px-4 py-2.5 text-sm font-medium transition-colors ${
                activeTab === "comments"
                  ? "text-zinc-900 dark:text-zinc-100 border-b-2 border-sky-500"
                  : "text-zinc-400 dark:text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
              }`}
            >
              Comments ({comments.length})
            </button>
            <button
              type="button"
              onClick={() => setRailOpen(false)}
              className="px-3 py-2.5 text-zinc-400 dark:text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 transition-colors"
              aria-label="Collapse panel"
              title="Collapse panel"
            >
              <svg
                width="16"
                height="16"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <polyline points="5 3 10 8 5 13" />
                <polyline points="9 3 14 8 9 13" />
              </svg>
            </button>
          </div>

          {/* Tab content */}
          <div className="flex-1 overflow-hidden">
            <div className={activeTab === "transcript" ? "h-full" : "hidden"}>
              <TranscriptPane
                transcriptUrl={transcriptUrl}
                currentTime={currentTime}
                onWordClick={seekTo}
              />
            </div>
            <div className={activeTab === "comments" ? "h-full" : "hidden"}>
              <CommentsPane
                recordingId={recordingId}
                comments={comments}
                me={me}
                highlightedCommentId={highlightedCommentId}
                currentTime={currentTime}
                onCommentCreated={handleCommentCreated}
                onCommentDeleted={handleCommentDeleted}
                onCommentClick={seekAndHighlight}
              />
            </div>
          </div>
        </div>
      ) : (
        <div className="hidden lg:flex lg:shrink-0 lg:sticky lg:top-4 lg:self-start">
          <button
            type="button"
            onClick={() => setRailOpen(true)}
            className="p-2 rounded-lg border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900/50 text-zinc-400 dark:text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800/50 transition-colors"
            aria-label="Expand panel"
            title="Expand panel"
          >
            <svg
              width="16"
              height="16"
              viewBox="0 0 16 16"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <polyline points="11 3 6 8 11 13" />
              <polyline points="7 3 2 8 7 13" />
            </svg>
          </button>
        </div>
      )}
    </div>
  );
}
