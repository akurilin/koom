# Post-Upload Processing

Everything the macOS client does on-device after the MP4 finishes uploading: local titles, word-level transcripts, and thumbnail generation. All three are best-effort, private, and never block the share link.

## Local titles and transcripts

Recordings that otherwise would have stayed untitled can get a short descriptive title and a word-level transcript on the same Mac that made the recording. There are no cloud inference APIs, third-party telemetry calls, or server-side workers.

Transcription and title generation intentionally have different readiness rules. WhisperKit runs whenever post-upload processing is enabled. Local title generation is an optional add-on: if its model is still downloading or unavailable when a recording's transcript finishes, koom preserves and uploads the transcript but skips that recording's title. There is no pending-title queue or later retry state.

### Stages

1. **Extract.** `AVAssetReader` pulls microphone audio from the finalized MP4 into 16 kHz mono float PCM. No ffmpeg and no temporary audio file.
2. **Transcribe.** An actor-wrapped `WhisperKit` instance runs `openai_whisper-small.en` with word timestamps. The model loads lazily and stays resident for the app session. WhisperKit manages its initial model download in the standard Hugging Face cache.
3. **Generate a local title when ready.** The transcript goes to a loopback-only `llama-server` launched from koom's app bundle. The selected GGUF model stays loaded until the user switches models, deletes it, or quits koom. The prompt asks for an English, 4–10 word, sentence-case title with no quotes, prefix, or trailing period; the client sanitizes the result before use.
4. **Persist.** The title is `PATCH`ed onto the `recordings` row. The timed transcript is uploaded as JSON to `PUT /api/admin/recordings/[id]/transcript`, which writes an R2 sidecar at `recordings/{id}/transcript.json`. The watch page fetches that public sidecar and degrades gracefully when it is absent.

### Runtime and model lifecycle

Users do not install an inference provider. `client/scripts/build-app.sh` downloads a pinned, checksummed macOS release of [llama.cpp](https://github.com/ggml-org/llama.cpp) and copies `llama-server`, its dynamic libraries, and its license into the app bundle.

On first launch, koom downloads the selected model in the background to:

```text
~/Library/Application Support/koom/models/
```

The download is checked against the byte size and SHA-256 hash in `client/Resources/local-title-models.json` before its `.part` file is promoted to a usable GGUF. The catalog also drives the model manager in Settings, including enable/disable, selection, download, atomic redownload, and delete actions. Deleting the selected model disables local title generation so it does not unexpectedly return on the next launch. Model URLs include immutable Hugging Face revisions.

The shipped catalog currently contains:

- Qwen3.5 0.8B Q4_0 — recommended default, about 563 MB
- Qwen3 1.7B Q4_K_M — balanced option, about 1.28 GB
- Qwen3 4B Q4_K_M — higher-quality option, about 2.5 GB

All three catalog entries are Apache-2.0 models. Once the chosen files are present, both transcription and title inference work offline. A model download naturally requires internet access.

### Isolation and debugging

The server binds to `127.0.0.1` on a koom-owned port and requires a fresh random bearer token for every app session. It exposes no web UI or slot inspection endpoint. The token is held in memory and is not written to logs or preferences.

Persistent client logs live in `~/Library/Logs/koom/`. llama.cpp stdout and stderr go to `local-title-server.log` in the same directory. **Troubleshooting → Reveal Logs in Finder** opens that directory.

`npm run doctor` validates the curated catalog and the pinned llama.cpp packaging recipe. It does not require a model to have been downloaded: model installation is client-managed and optional.

## Thumbnail generation

Each completed recording also gets a best-effort JPEG thumbnail generated locally. This stays intentionally simple: no queue, worker, or background cloud media pipeline.

1. **Extract.** `AVAssetImageGenerator` reads a still frame from the finalized MP4 and encodes it as JPEG without mutating the source.
2. **Upload.** The client sends the JPEG to `PUT /api/admin/recordings/[id]/thumbnail`.
3. **Store.** The backend writes `recordings/{id}/thumbnail-v1.jpg` to R2.
4. **Render.** Recording payloads expose `thumbnailUrl`; list views fall back to `videoUrl#t=0.1` when the JPEG is absent.

A thumbnail failure never blocks the MP4 upload, prevents the share URL from opening, or deletes the local recording.
