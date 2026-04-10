/**
 * Thin strip below the <video> element showing a dot for each
 * comment's timestamp. Clicking a dot seeks the video and
 * highlights the comment in the pane.
 *
 * Renders nothing meaningful if durationSeconds is null or 0
 * (we can't compute positions without a known duration).
 */

"use client";

interface TimelineComment {
  id: string;
  timestampSeconds: number;
}

interface TimelineMarkersProps {
  comments: TimelineComment[];
  durationSeconds: number | null;
  onMarkerClick: (commentId: string, timestampSeconds: number) => void;
}

export function TimelineMarkers({
  comments,
  durationSeconds,
  onMarkerClick,
}: TimelineMarkersProps) {
  const hasDuration = durationSeconds != null && durationSeconds > 0;

  return (
    <div
      data-testid="timeline-markers-strip"
      className="relative w-full h-2 bg-zinc-800 rounded-full mt-1"
    >
      {hasDuration &&
        comments.map((c) => {
          const pct = Math.min(
            (c.timestampSeconds / durationSeconds) * 100,
            100,
          );
          return (
            <button
              key={c.id}
              data-testid="timeline-marker"
              type="button"
              onClick={() => onMarkerClick(c.id, c.timestampSeconds)}
              className="absolute top-0 w-2 h-2 rounded-full bg-sky-400 hover:bg-sky-300 cursor-pointer transition-colors -translate-x-1/2"
              style={{ left: `${pct}%` }}
              title={formatTimestamp(c.timestampSeconds)}
            />
          );
        })}
    </div>
  );
}

function formatTimestamp(seconds: number): string {
  const clamped = Math.max(0, seconds);
  const whole = Math.floor(clamped);
  const tenths = Math.round((clamped - whole) * 10);
  const m = Math.floor(whole / 60);
  const s = whole % 60;
  const base = `${m}:${s.toString().padStart(2, "0")}`;
  return tenths > 0 ? `${base}.${tenths}` : base;
}
