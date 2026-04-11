# Crash Recovery

How koom keeps a recording alive when the app is force-quit, crashes, or loses power mid-capture.

## Summary

If koom is interrupted mid-recording, the next launch finds the unfinished recording and offers to recover it. The writer flushes a fresh MP4 fragment every ~2 seconds, so the bytes already on disk stay playable without a clean stop.

## Under the hood

- While recording, the client writes fragmented MP4 segments under `~/Movies/koom/.sessions/<session-id>/segment-NNNN.mp4` next to a `session.json` manifest tracking the display, camera, mic, and per-segment status.
- On a clean stop of a single-segment session, the segment is moved into its `koom_*.mp4` final path and the session directory is deleted — no copy, no re-encode.
- On the next launch after a crash, the orphaned session triggers an "Interrupted recording found" dialog with four options:
  - **Resume Recording** — appends a new segment on top of the existing ones and keeps going
  - **Finish Partial** — stitches whatever segments exist into the final file now
  - **Not Now** — leaves the session for later
  - **Discard** — deletes the session directory
- Multi-segment finalizations (resumed recordings and partial finishes) go through `AVAssetExportSession`'s passthrough preset, so the stitch still has no re-encode.
- Quitting while a recording is active first triggers a "Stop and Save / Discard / Keep Recording" prompt before the app shuts down.
