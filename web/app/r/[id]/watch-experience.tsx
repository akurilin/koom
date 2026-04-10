/**
 * Client component that orchestrates the video player, timeline
 * markers, and comments pane. Owns the shared state between them
 * (comments list, highlighted comment, video ref for seeking).
 *
 * Receives initial data from the server component (page.tsx)
 * so the first paint already has comments — no loading spinner.
 */

"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import { formatBytes, formatDate, formatDuration } from "@/lib/format";

import { CommentsPane, type CommentData, type MeData } from "./comments-pane";
import { TimelineMarkers } from "./timeline-markers";
import { VideoPlayer } from "./video-player";

interface WatchExperienceProps {
  recordingId: string;
  videoUrl: string;
  contentType: string;
  displayTitle: string;
  createdAt: string;
  durationSeconds: number | null;
  sizeBytes: number;
  initialComments: CommentData[];
  initialMe: MeData | null;
}

export function WatchExperience({
  recordingId,
  videoUrl,
  contentType,
  displayTitle,
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

  return (
    <div className="w-full flex flex-col lg:flex-row gap-6">
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
        <div className="mt-6 sm:mt-8">
          <h1 className="text-xl sm:text-2xl font-medium leading-tight break-words">
            {displayTitle}
          </h1>
          <div className="mt-3 text-sm text-zinc-400 flex flex-wrap gap-x-4 gap-y-1">
            <span>{formatDate(createdAt)}</span>
            {durationSeconds !== null && (
              <span>{formatDuration(durationSeconds)}</span>
            )}
            <span>{formatBytes(sizeBytes)}</span>
          </div>
        </div>
      </div>

      {/* Right column: comments */}
      <div className="w-full lg:w-[360px] lg:shrink-0 lg:sticky lg:top-8 lg:max-h-[calc(100vh-4rem)] bg-zinc-900/50 rounded-lg border border-zinc-800 overflow-hidden flex flex-col max-h-[500px] lg:max-h-[calc(100vh-4rem)]">
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
  );
}
