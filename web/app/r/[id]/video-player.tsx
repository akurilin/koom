/**
 * Client component wrapping the native HTML5 <video> element.
 *
 * Three responsibilities beyond plain `<video controls>`:
 *
 *   1. On mount, read `?t=<seconds>` from the URL and seek the video
 *      to that position once enough metadata is loaded. Lets share
 *      URLs like `/r/abc?t=42` jump straight to the 42-second mark.
 *   2. Surface a graceful fallback message if the browser can't
 *      play the content type.
 *   3. Accept an optional external ref so parent components (e.g.
 *      WatchExperience) can seek programmatically.
 *
 * Uses `window.location.search` rather than Next.js's
 * `useSearchParams` because the latter forces the entire tree into
 * dynamic rendering via a Suspense bailout, and we only need the
 * value once at mount time — not reactively.
 */

"use client";

import { type RefObject, useEffect, useRef } from "react";

interface VideoPlayerProps {
  src: string;
  contentType: string;
  /** Optional external ref for programmatic seek from parent. */
  videoRef?: RefObject<HTMLVideoElement | null>;
  /** Called on timeupdate with the current playback time. */
  onTimeUpdate?: (currentTime: number) => void;
}

export function VideoPlayer({
  src,
  contentType,
  videoRef: externalRef,
  onTimeUpdate,
}: VideoPlayerProps) {
  const internalRef = useRef<HTMLVideoElement>(null);
  const ref = externalRef ?? internalRef;

  useEffect(() => {
    const video = ref.current;
    if (!video) return;

    const seconds = parseDeepLinkSeconds(window.location.search);
    if (seconds === null) return;

    // If metadata is already loaded we can seek right away.
    // Otherwise wait until it is — before that, setting currentTime
    // has no effect.
    const seek = () => {
      video.currentTime = seconds;
    };

    if (video.readyState >= /* HAVE_METADATA */ 1) {
      seek();
      return;
    }

    video.addEventListener("loadedmetadata", seek, { once: true });
    return () => {
      video.removeEventListener("loadedmetadata", seek);
    };
  }, [ref]);

  useEffect(() => {
    if (!onTimeUpdate) return;
    const video = ref.current;
    if (!video) return;

    const handler = () => onTimeUpdate(video.currentTime);
    video.addEventListener("timeupdate", handler);
    return () => video.removeEventListener("timeupdate", handler);
  }, [ref, onTimeUpdate]);

  return (
    <video
      ref={ref}
      data-testid="video-player"
      src={src}
      controls
      preload="metadata"
      playsInline
      className="w-full rounded-lg shadow-2xl shadow-black/20 dark:shadow-black/60 bg-black aspect-video"
    >
      <p className="p-4 text-zinc-500 dark:text-zinc-400 text-sm">
        Your browser cannot play this {contentType} file.
      </p>
    </video>
  );
}

/**
 * Parse the `t` query parameter as a non-negative number of
 * seconds. Returns null if absent, malformed, or out of range.
 * Accepts integers or decimals — `?t=42` and `?t=42.5` are both
 * valid.
 */
function parseDeepLinkSeconds(search: string): number | null {
  const params = new URLSearchParams(search);
  const raw = params.get("t");
  if (raw === null) return null;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) return null;
  return value;
}
