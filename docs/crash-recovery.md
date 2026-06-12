# Crash Recovery

How koom keeps a recording alive when the app is force-quit, crashes, or loses power mid-capture.

## Summary

If koom is interrupted mid-recording, the next launch lists the unfinished session in the Recovery tab. While recording, the writer rolls onto a fresh segment file every ~30 seconds without stopping capture, finishing each previous segment as a complete, playable MP4 — so a crash loses at most the segment being written.

## Under the hood

- While recording, the client writes plain MP4 segments under `~/Movies/koom/<env>/.sessions/<session-id>/segment-NNNN.mp4` next to a `session.json` manifest tracking the display, camera, mic, and per-segment status.
- Every ~30 seconds of media time the recorder starts a new writer on the next segment file and finalizes the previous one in the background; `SCStream` capture never stops, and the seam costs no media. (Earlier versions kept one writer alive with `movieFragmentInterval` instead; that was retired because macOS's fragmented-MP4 writer intermittently killed recordings at fragment-flush boundaries.)
- On a clean stop, a single-segment recording is moved into its `koom_*.mp4` final path with no copy and no re-encode; multi-segment recordings are stitched through `AVAssetExportSession`'s passthrough preset, which remuxes without re-encoding. Either way the session directory is deleted afterward.
- On the next launch after a crash, orphaned sessions appear in the main panel's **Recovery** tab, each with three actions:
  - **Resume** — appends a new segment on top of the existing ones and keeps going
  - **Finish & upload** — stitches whatever segments exist into the final file now
  - **Discard** — deletes the session directory
- An unreadable segment (e.g. a writer that died mid-file) is skipped during stitching rather than failing the whole recovery.
- Quitting while a recording is active first triggers a "Stop and Save / Discard / Keep Recording" prompt before the app shuts down.
