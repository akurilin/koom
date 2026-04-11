"use client";

import { useCallback, useEffect, useRef, useState } from "react";

interface TranscriptWord {
  word: string;
  start: number;
  end: number;
}

interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
  words: TranscriptWord[];
}

interface TranscriptData {
  segments: TranscriptSegment[];
}

interface TranscriptPaneProps {
  transcriptUrl: string;
  currentTime: number;
  onWordClick: (startSeconds: number) => void;
}

function formatTimestamp(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export function TranscriptPane({
  transcriptUrl,
  currentTime,
  onWordClick,
}: TranscriptPaneProps) {
  const [state, setState] = useState<{
    transcript: TranscriptData | null;
    loading: boolean;
    error: boolean;
  }>({ transcript: null, loading: true, error: false });
  const activeWordRef = useRef<HTMLSpanElement>(null);
  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const userScrolledRef = useRef(false);
  const scrollTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetch(transcriptUrl)
      .then((res) => {
        if (!res.ok) throw new Error("not found");
        return res.json();
      })
      .then((data: TranscriptData) => {
        if (!cancelled) {
          setState({ transcript: data, loading: false, error: false });
        }
      })
      .catch(() => {
        if (!cancelled) {
          setState({ transcript: null, loading: false, error: true });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [transcriptUrl]);

  const { transcript, loading, error } = state;

  // Track user scroll to avoid fighting with auto-scroll
  const handleScroll = useCallback(() => {
    userScrolledRef.current = true;
    if (scrollTimeoutRef.current) clearTimeout(scrollTimeoutRef.current);
    scrollTimeoutRef.current = setTimeout(() => {
      userScrolledRef.current = false;
    }, 3000);
  }, []);

  // Auto-scroll to keep the active word visible
  useEffect(() => {
    if (userScrolledRef.current) return;
    if (!activeWordRef.current || !scrollContainerRef.current) return;
    const container = scrollContainerRef.current;
    const el = activeWordRef.current;
    const elTop = el.offsetTop - container.offsetTop;
    const elBottom = elTop + el.offsetHeight;
    const scrollTop = container.scrollTop;
    const viewHeight = container.clientHeight;
    if (elTop < scrollTop || elBottom > scrollTop + viewHeight) {
      container.scrollTop = elTop - viewHeight / 3;
    }
  }, [currentTime]);

  if (loading) {
    return (
      <div className="flex-1 flex items-center justify-center h-full">
        <p className="text-sm text-zinc-400 dark:text-zinc-500">
          Loading transcript…
        </p>
      </div>
    );
  }

  if (error || !transcript) {
    return (
      <div className="flex-1 flex items-center justify-center h-full">
        <p className="text-sm text-zinc-400 dark:text-zinc-500 text-center px-4">
          No transcript available for this recording.
        </p>
      </div>
    );
  }

  return (
    <div
      ref={scrollContainerRef}
      onScroll={handleScroll}
      className="flex-1 overflow-y-auto h-full"
    >
      <div className="divide-y divide-zinc-200/50 dark:divide-zinc-800/50">
        {transcript.segments.map((segment, segIdx) => {
          const isActiveSegment =
            currentTime >= segment.start && currentTime < segment.end;
          return (
            <div
              key={segIdx}
              className={`flex gap-3 px-4 py-3 transition-colors ${
                isActiveSegment ? "bg-sky-50/50 dark:bg-zinc-800/30" : ""
              }`}
            >
              <button
                type="button"
                onClick={() => onWordClick(segment.start)}
                className="shrink-0 text-xs font-mono text-zinc-400 dark:text-zinc-500 hover:text-sky-400 transition-colors pt-0.5 w-10 text-right"
              >
                {formatTimestamp(segment.start)}
              </button>
              <p className="text-sm leading-relaxed flex-1">
                {segment.words.length > 0 ? (
                  segment.words.map((word, wordIdx) => {
                    const isActive =
                      currentTime >= word.start && currentTime < word.end;
                    return (
                      <span
                        key={wordIdx}
                        ref={isActive ? activeWordRef : undefined}
                        onClick={() => onWordClick(word.start)}
                        className={`cursor-pointer rounded px-0.5 transition-colors hover:bg-sky-100 dark:hover:bg-sky-900/50 hover:text-sky-800 dark:hover:text-sky-200 ${
                          isActive
                            ? "bg-sky-100 dark:bg-sky-900/60 text-sky-800 dark:text-sky-100"
                            : "text-zinc-700 dark:text-zinc-300"
                        }`}
                      >
                        {word.word}
                      </span>
                    );
                  })
                ) : (
                  <span className="text-zinc-700 dark:text-zinc-300">
                    {segment.text}
                  </span>
                )}
              </p>
            </div>
          );
        })}
      </div>
    </div>
  );
}
