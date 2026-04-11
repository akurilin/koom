# Post-Upload Processing

Everything the macOS client does on-device after the MP4 finishes uploading: auto-titles, word-level transcripts, and thumbnail generation. All three are best-effort, private, and never block the share link.

## Auto-titling and transcripts

Recordings that otherwise would have stayed untitled get a short descriptive title and a word-level transcript generated on the same machine that did the recording — no cloud APIs, no third-party telemetry, no server-side worker. One WhisperKit pass produces both artifacts. The pipeline runs once per recording during post-upload processing. Everything remains best-effort: any failure (no mic track, WhisperKit error, Ollama request failure, empty transcript) logs a line, leaves the `title` column `NULL`, and skips the transcript upload.

### Stages

All stages run in-process on the macOS client:

1. **Extract.** `AVAssetReader` pulls the mic audio out of the finalized MP4 into 16 kHz mono float PCM. No ffmpeg, no temp files.
2. **Transcribe.** An actor-wrapped `WhisperKit` instance runs the CoreML model against the PCM buffer with `wordTimestamps: true`, producing a `TimedTranscript` of segments, each with a start/end time and an array of words with their own per-word timing. The instance is loaded lazily on first use and memoized for the rest of the process, so the ~500 MB model download only happens once (into the standard HuggingFace Hub cache at `~/.cache/huggingface/hub/`).
3. **Summarize.** The plain-text rendering of the transcript is sent to a local Ollama model via `POST http://localhost:11434/api/generate` with `think: false` (important — reasoning-capable models like `gemma4:e4b` otherwise route their output into a separate `thinking` field and return an empty `response`). The client asks for a 4–10 word title and sanitizes it (strips `Title:` prefixes, smart/straight quotes, trailing punctuation, clamps to 10 words).
4. **Persist.** The title is `PATCH`ed onto the `recordings` row via `PATCH /api/admin/recordings/[id]`. Pending rows (upload still in flight) are also allowed to take a title so the auto-titler can land early on fast uploads. The timed transcript is uploaded as JSON to `PUT /api/admin/recordings/[id]/transcript`, which writes it to R2 at `recordings/{id}/transcript.json` as sidecar metadata — there is no database column for the transcript. The watch page fetches the public R2 URL directly and falls back gracefully when the sidecar object does not exist.

### Defaults

The shipped client defaults are compiled into `AutotitleConfiguration.swift`:

- Whisper model: `openai_whisper-small.en`
- Ollama URL: `http://localhost:11434`
- Ollama model: `gemma4:e4b`
- Auto-title enabled: yes

At launch the app performs a best-effort Ollama warmup itself. If the configured URL is the default local HTTP endpoint, koom will try to start `ollama serve` automatically before giving up. Missing Ollama or a missing model no longer blocks app launch; the app logs the issue, surfaces a small status warning, and skips auto-title work until Ollama becomes available again.

`npm run doctor` has an "Auto-title (Ollama)" section that verifies Ollama is reachable and the configured model has been pulled. Those checks remain non-fatal so the rest of the doctor sweep still runs.

## Thumbnail generation

Each completed recording also gets a best-effort JPEG thumbnail generated locally on the macOS client. This stays intentionally simple: no queue, no worker, no background cloud media pipeline.

Stages, all on the macOS client:

1. **Extract.** `AVAssetImageGenerator` reads a still frame from the finalized MP4 and encodes it as JPEG. No `ffmpeg`, no full-file re-download from R2, and no mutation of the source recording.
2. **Upload.** The client sends that JPEG to `PUT /api/admin/recordings/[id]/thumbnail`.
3. **Store.** The web backend writes the sidecar object to Cloudflare R2 at `recordings/{id}/thumbnail-v1.jpg`.
4. **Render.** Admin/public recording payloads expose `thumbnailUrl`, and list views use that image first, falling back to `videoUrl#t=0.1` if the sidecar JPEG is missing.

Like auto-titling, thumbnail generation is best-effort. A thumbnail failure never blocks the MP4 upload, never prevents the share URL from opening, and never deletes or mutates the local recording.
