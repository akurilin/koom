# Recording Output

How the koom macOS client captures video to disk, and what to expect in terms of codec, bitrate, and file size.

## Summary

The macOS client captures with `ScreenCaptureKit` and writes directly to disk as H.264 MP4 — there is no post-capture transcode or resize pass during normal recording. koom keeps that local recording untouched. If upload optimization is enabled in Settings, the upload path can also create and upload a smaller MP4 derivative via `ffmpeg` when that re-encode is meaningfully smaller. Recordings stitched back together after a crash go through an `AVAssetExportSession` passthrough mux (see [Crash recovery](crash-recovery.md)), but even then nothing is re-encoded.

## File and codec details

- **Path:** `~/Movies/koom/koom_YYYY-MM-DD_HH-mm-ss.mp4`
- **Codec:** H.264 (High Auto Level)
- **Capture cadence:** 15 fps by default, 30 fps optional in Settings, keyframe every ~2 seconds
- **Resolution:** native capture size of the selected display (no preset, no downscaling)
- **Bitrate heuristic:** `max(width × height × 4, 8 Mb/s)`
- **Upload optimization:** optional best-effort `ffmpeg` pass (`libx264 -preset slow -crf 18`) that keeps the local file and uploads a smaller derivative only when it saves at least 10%
- **Audio:** screen/system audio disabled; microphone optional
- **Cursor:** included

## Approximate file sizes

Worst-case local file sizes under the current bitrate heuristic, before any optional upload optimization:

| Resolution | Bitrate    | ~Size per minute |
| ---------- | ---------- | ---------------- |
| 1920×1080  | ~8.3 Mb/s  | ~62 MB           |
| 2560×1440  | ~14.7 Mb/s | ~111 MB          |
| 3840×2160  | ~33.2 Mb/s | ~249 MB          |

The file is already compressed during capture, so it is not a raw or ProRes master — but 4K recordings can still get large quickly. Static screen recordings usually land well below those ceilings, especially at 15 fps. The client never deletes local files, and upload failures never destroy the source.
