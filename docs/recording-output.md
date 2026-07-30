# Recording Output

How the koom macOS client captures video to disk, and what to expect in terms of codec, bitrate, and file size.

## Summary

The macOS client captures with `ScreenCaptureKit` and writes directly to disk as H.264 MP4 at the resolution selected in Settings. ScreenCaptureKit scales the display's high-density backing surface before frames reach koom, so there is no post-capture resize pass. If recording optimization is enabled, `ffmpeg` re-encodes the video at the same resolution and replaces the local MP4 only when the result is meaningfully smaller. Recordings stitched back together after a crash normally go through an `AVAssetExportSession` passthrough mux (see [Crash recovery](crash-recovery.md)).

## File and codec details

- **Path:** `~/Movies/koom/koom_YYYY-MM-DD_HH-mm-ss.mp4`
- **Codec:** H.264 (High Auto Level)
- **Capture cadence:** 30 fps by default, 15 fps optional in Settings, keyframe every ~2 seconds
- **Resolution:** 1080p by default; 720p and 4K are available in Settings
- **Scaling:** presets are aspect-preserving upper bounds (1280×720, 1920×1080, or 3840×2160), swap for portrait displays, and never enlarge a lower-resolution source
- **Bitrate heuristic:** `max(width × height × 4, 4 Mb/s)`
- **Recording optimization:** optional best-effort `ffmpeg` pass (`libx264 -preset slow -crf 18`) that preserves the selected resolution and replaces the local file only when it saves at least 10%
- **Audio:** screen/system audio disabled; microphone optional
- **Cursor:** included

## Approximate file sizes

Worst-case local file sizes under the current bitrate heuristic, before any optional upload optimization:

| Resolution | Bitrate    | ~Size per minute |
| ---------- | ---------- | ---------------- |
| 1280×720   | 4.0 Mb/s   | ~30 MB           |
| 1920×1080  | ~8.3 Mb/s  | ~62 MB           |
| 3840×2160  | ~33.2 Mb/s | ~249 MB          |

The file is already compressed during capture, so it is not a raw or ProRes master — but 4K recordings can still get large quickly. Static screen recordings often land below these rough figures, and the optional optimizer may reduce them further. The client never deletes a local recording because an upload failed.
