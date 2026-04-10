# koom

[![CI](https://github.com/akurilin/koom/actions/workflows/ci.yml/badge.svg)](https://github.com/akurilin/koom/actions/workflows/ci.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/akurilin/koom)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Next.js 16](https://img.shields.io/badge/Next.js-16-000000?logo=next.js&logoColor=white)](https://nextjs.org)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![style: prettier](https://img.shields.io/badge/style-prettier-ff69b4.svg)](https://prettier.io)
[![lint: eslint](https://img.shields.io/badge/lint-eslint-4B32C3.svg)](https://eslint.org)

`koom` is a self-deployable, Loom-style screen recorder for a single user. You record locally in the macOS app, the finished MP4 auto-uploads to storage you own, and you get a shareable watch URL that opens in any browser. No SaaS subscription, no third party holding your videos, and typically **$0–5/month** at personal scale.

## Why koom

Loom is great, but you don't actually own your recordings, you pay monthly, and the videos live on someone else's infrastructure. koom is the same core loop — record, auto-upload, share a link — but:

- **You own the bytes.** Videos sit in your Cloudflare R2 bucket. No vendor can deprecate, paywall, or delete them.
- **Zero-egress storage.** R2 has no bandwidth fees, so cost stays flat no matter how much the links get shared.
- **Deliberately narrow scope.** Single-tenant, one admin secret, no teams, no stored transcripts, no search beyond a simple list. The whole stack fits in your head.
- **Cheap steady state.** Vercel Hobby + Supabase free tier + R2 free tier. The only variable cost is R2 storage above 10 GB.
- **Private auto-titles.** Recordings get a short descriptive title generated locally via WhisperKit + Ollama — the audio never leaves your machine, and the feature is an opt-out, not an extra subscription.
- **Local thumbnails.** Recordings also get a sidecar JPEG generated on-device and uploaded next to the video in R2, so list views can use a lightweight image instead of seeking into the MP4 whenever the thumbnail is available.

v1 intentionally leaves a lot out: no accounts, no stored transcripts or captions, no transcoding, no custom domains. See [`docs/monorepo-backend-plan.md`](docs/monorepo-backend-plan.md) for the full decision record.

## Architecture

koom is a small monorepo split by runtime:

| Component   | Stack                                            | Role                                                           |
| ----------- | ------------------------------------------------ | -------------------------------------------------------------- |
| `client/`   | Swift 6, SwiftUI, AVFoundation, ScreenCaptureKit | Records the screen, uploads the finished file                  |
| `web/`      | Next.js 16 (App Router), TypeScript, React 19    | Public watch pages, admin UI, backend API routes               |
| `supabase/` | Hand-written SQL migrations, managed via `pg`    | `recordings` + `comments` tables (no ORM)                      |
| `scripts/`  | TypeScript, run through `tsx`                    | R2 provisioning (`r2:setup`) and stack verification (`doctor`) |

Deployment targets:

- **Web tier:** Vercel Hobby
- **Metadata:** Supabase Postgres (used purely as a Postgres provider — no Supabase Auth, no Supabase Storage)
- **Video + CDN:** Cloudflare R2 with its built-in CDN
- **Auth:** a single deployment-wide admin secret; browsers use a signed cookie, the desktop client uses `Authorization: Bearer`. Anonymous commenters are tracked by a plain UUID cookie.

### How a recording flows end to end

1. The macOS client records to `~/Movies/koom/koom_YYYY-MM-DD_HH-mm-ss.mp4` and keeps the local copy permanently. Recording is staged through a fragmented MP4 session so a crash mid-capture can be recovered on the next launch (see [Crash recovery](#crash-recovery)).
2. On completion, the client asks `POST /api/admin/uploads/init` for a presigned R2 `PUT` URL and writes a `pending` row to Postgres.
3. The client `PUT`s the file straight to R2 — bytes never flow through Vercel.
4. In parallel with step 3, local post-upload processing kicks off on the Mac. The auto-titler extracts the mic track via `AVAssetReader`, transcribes it in-process with WhisperKit, and asks a local Ollama model for a short title. The thumbnail generator also grabs a JPEG still frame from the finalized MP4. Nothing leaves the machine except the derived title/thumbnail artifacts you choose to upload back into your own stack.
5. `POST /api/admin/uploads/complete` `HEAD`s the object to confirm it landed, flips the row to `complete`, and returns the share URL. If the auto-titler produced a title, the client `PATCH`es it onto the row. If thumbnail generation succeeded, the client uploads the JPEG to `PUT /api/admin/recordings/[id]/thumbnail`, and the backend stores it in R2 at `recordings/{id}/thumbnail-v1.jpg`.
6. The client copies the share URL to the clipboard and opens it. Anyone with the link can watch at `/r/[id]` (with `?t=` timestamp deep-linking) and leave timestamped comments. The recordings list APIs expose `thumbnailUrl`; list views prefer that sidecar JPEG and fall back to `videoUrl#t=0.1` if no thumbnail exists.

The Next.js app holds all R2 and Postgres credentials. The desktop client only knows the web URL and the admin secret; every interaction with R2 is gated by short-lived presigned URLs.

## Repository layout

```text
client/                  macOS Swift package (recorder + uploader)
  Sources/koom/          SwiftUI app, ScreenCaptureKit, upload pipeline
  Package.swift
  scripts/               build-app.sh, run.sh, install-app.sh
web/                     Next.js app (frontend + backend)
  app/                   App Router pages
    r/[id]/              public watch page + comments pane
    login/               public login page
    app/                 admin UI (recordings list)
    api/public/          public JSON endpoints (recordings, comments)
    api/admin/           admin JSON endpoints (session, uploads, recordings)
  lib/
    db/                  thin `pg` Pool + parameterized query helpers
    r2/                  S3-compatible R2 client + presigning
    auth/                admin session, bearer validation, commenter identity
  tests/                 Vitest integration + Playwright E2E
supabase/
  migrations/            hand-written SQL, applied via the Supabase CLI
  config.toml            local stack configuration
scripts/
  doctor.ts              read-only verification sweep across the full stack
  r2-orphans.ts          audit or delete orphaned recording objects in R2
  r2-setup.ts            provisions the production R2 bucket + credentials
  r2-setup-test.ts       provisions the isolated E2E test bucket
  test.sh                unified test runner (web + client)
  clean-web-cache.js     removes rebuildable web workspace artifacts
  build-app.sh, run.sh, install-app.sh   thin wrappers that delegate into client/scripts
docs/
  monorepo-backend-plan.md   architectural decision record
```

## Requirements

- macOS 26 Tahoe or later for the desktop client
- Node.js 20+ for the web app and operator scripts
- A Cloudflare account (R2 free tier is enough to start)
- A Supabase project — or Docker, for the local Supabase stack via `npm run db:start`
- Optional: [Ollama](https://ollama.com) if you want local title generation (`brew install ollama && ollama pull gemma4:e4b`). koom uses Ollama as the local LLM that turns Whisper transcripts into short recording titles. The shipped client defaults to `http://localhost:11434` + `gemma4:e4b`, warms that model in-app at launch, and will auto-start `ollama serve` for the default local URL when it can. Auto-title stays best-effort: the app keeps launching even if Ollama is unavailable, and the failure is logged under `~/Library/Logs/koom/`.
- Optional local tooling so the pre-commit hook can run: `brew install gitleaks shellcheck`

The macOS client also needs Screen Recording permission, Camera permission (if using the face overlay), and Microphone permission (if recording narration).

## Getting started

```bash
# 1. install dependencies (npm workspaces, husky, etc.)
npm install

# 2. bring up local Postgres via the Supabase CLI and apply migrations
npm run db:start
npm run db:reset

# 3. provision a Cloudflare R2 bucket + credentials (writes back into web/.env.local)
npm run r2:setup

# 4. verify the stack end to end (db reachable, R2 works, range requests OK)
npm run doctor

# 5. create the local macOS code-signing identity once
#    (recommended before first client launch so Keychain trust survives rebuilds)
./scripts/setup-dev-codesign.sh

# 6. run the web app
npm run dev -w web

# 7. build and run the macOS client for development
./scripts/run.sh

# 8. install the signed release app into /Applications
./scripts/install-app.sh
```

`npm run doctor` is the authoritative "is this environment actually usable?" check. It's always safe to re-run and exercises the database, R2 credentials, HTTP range support that browser `<video>` scrubbing depends on, and on macOS it warns if the local desktop-client signing identity is missing or unusable.

`npm run r2:orphans` audits the shared R2 bucket for `recordings/{id}/...` objects that no longer have a matching row in the configured database set. It is dry-run by default; add `-- --delete` to remove confirmed orphans, and add `-- --prod-db-url ...` or `-- --prod-env-file ...` when you want to union a production database into the check.

## Development

| Task                                | Command                            |
| ----------------------------------- | ---------------------------------- |
| Clean rebuildable web caches        | `npm run web:clean`                |
| Lint the web workspace              | `npm run lint`                     |
| Check formatting (Prettier)         | `npm run format:check`             |
| Auto-fix formatting                 | `npm run format`                   |
| Lint Swift sources                  | `npm run swift:lint`               |
| Auto-fix Swift formatting           | `npm run swift:format`             |
| ShellCheck every tracked `.sh`      | `npm run shellcheck`               |
| Push migrations to production       | `npm run db:push`                  |
| Audit orphaned R2 recording files   | `npm run r2:orphans`               |
| Web unit + integration tests        | `npm test -w web`                  |
| Web end-to-end tests (Playwright)   | `npm run test:e2e -w web`          |
| Build the macOS client bundle       | `./scripts/build-app.sh`           |
| Build a release macOS client bundle | `./scripts/build-app.sh --release` |
| Install the signed release app      | `./scripts/install-app.sh`         |
| Run the macOS client in foreground  | `./scripts/run.sh`                 |

`npm run web:clean` removes the web workspace's rebuildable artifacts (`web/.next`, `web/node_modules/.vite`, and Playwright/Vitest output directories). It refuses to run while a live `next dev` process still owns the workspace.

A pre-commit hook (husky + lint-staged) runs ESLint, Prettier, `swift format`, ShellCheck, and gitleaks against staged changes before any commit lands. Swift sources use Apple's official `swift-format` (ships with the Swift 6 toolchain) against the repo-level `.swift-format` config. The rest of the checks also run in GitHub Actions on push and pull requests, plus a full-history gitleaks scan.

The desktop app writes persistent logs to `~/Library/Logs/koom/koom.log` and keeps one rotated `koom.previous.log`. From the app itself, use **Troubleshooting → Reveal Logs in Finder** to jump straight to that directory.

## Recording output

The macOS client captures with ScreenCaptureKit and writes directly to disk as H.264 MP4 — there is no post-capture transcode or resize pass during normal recording. koom keeps that local recording untouched. If upload optimization is enabled in Settings, the upload path can also create and upload a smaller MP4 derivative via `ffmpeg` when that re-encode is meaningfully smaller. Recordings stitched back together after a crash go through an `AVAssetExportSession` passthrough mux — see [Crash recovery](#crash-recovery) — but even then nothing is re-encoded.

- **Path:** `~/Movies/koom/koom_YYYY-MM-DD_HH-mm-ss.mp4`
- **Codec:** H.264 (High Auto Level)
- **Capture cadence:** 15 fps by default, 30 fps optional in Settings, keyframe every ~2 seconds
- **Resolution:** native capture size of the selected display (no preset, no downscaling)
- **Bitrate heuristic:** `max(width × height × 4, 8 Mb/s)`
- **Upload optimization:** optional best-effort `ffmpeg` pass (`libx264 -preset slow -crf 18`) that keeps the local file and uploads a smaller derivative only when it saves at least 10%
- **Audio:** screen/system audio disabled; microphone optional
- **Cursor:** included

Approximate worst-case local file sizes under the current bitrate heuristic, before any optional upload optimization:

| Resolution | Bitrate    | ~Size per minute |
| ---------- | ---------- | ---------------- |
| 1920×1080  | ~8.3 Mb/s  | ~62 MB           |
| 2560×1440  | ~14.7 Mb/s | ~111 MB          |
| 3840×2160  | ~33.2 Mb/s | ~249 MB          |

The file is already compressed during capture, so it is not a raw or ProRes master — but 4K recordings can still get large quickly. Static screen recordings usually land well below those ceilings, especially at 15 fps. The client never deletes local files, and upload failures never destroy the source.

## Crash recovery

If koom is force-quit, crashes, or loses power mid-recording, the next launch finds the unfinished recording and offers to recover it. The writer flushes a fresh MP4 fragment every ~2 seconds, so the bytes already on disk stay playable without a clean stop.

Under the hood:

- While recording, the client writes fragmented MP4 segments under `~/Movies/koom/.sessions/<session-id>/segment-NNNN.mp4` next to a `session.json` manifest tracking the display, camera, mic, and per-segment status.
- On a clean stop of a single-segment session, the segment is moved into its `koom_*.mp4` final path and the session directory is deleted — no copy, no re-encode.
- On the next launch after a crash, the orphaned session triggers an "Interrupted recording found" dialog with four options: **Resume Recording** appends a new segment on top of the existing ones and keeps going; **Finish Partial** stitches whatever segments exist into the final file now; **Not Now** leaves it for later; **Discard** deletes the session directory.
- Multi-segment finalizations (resumed recordings and partial finishes) go through `AVAssetExportSession`'s passthrough preset, so the stitch still has no re-encode.
- Quitting while a recording is active first triggers a "Stop and Save / Discard / Keep Recording" prompt before the app shuts down.

## Auto-titling

Recordings that otherwise would have stayed untitled get a short descriptive title generated on the same machine that did the recording — no cloud APIs, no third-party telemetry, no server-side worker. The pipeline runs once per recording during post-upload processing. The title-generation steps themselves remain best-effort: any failure (no mic track, Ollama request failure, empty transcript) logs a line and leaves the `title` column `NULL`.

Stages, all in-process on the macOS client:

1. **Extract.** `AVAssetReader` pulls the mic audio out of the finalized MP4 into 16 kHz mono float PCM. No ffmpeg, no temp files.
2. **Transcribe.** An actor-wrapped `WhisperKit` instance runs the CoreML model against the PCM buffer. The instance is loaded lazily on first use and memoized for the rest of the process, so the ~500 MB model download only happens once (into the standard HuggingFace Hub cache at `~/.cache/huggingface/hub/`).
3. **Summarize.** The transcript is sent to a local Ollama model via `POST http://localhost:11434/api/generate` with `think: false` (important — reasoning-capable models like `gemma4:e4b` otherwise route their output into a separate `thinking` field and return an empty `response`). The client asks for a 4–10 word title and sanitizes it (strips `Title:` prefixes, smart/straight quotes, trailing punctuation, clamps to 10 words).
4. **Persist.** The title is `PATCH`ed onto the `recordings` row via `PATCH /api/admin/recordings/[id]`. Pending rows (upload still in flight) are also allowed to take a title so the auto-titler can land early on fast uploads.

The shipped client defaults are compiled into `AutotitleConfiguration.swift`:

- Whisper model: `openai_whisper-small.en`
- Ollama URL: `http://localhost:11434`
- Ollama model: `gemma4:e4b`
- Auto-title enabled: yes

At launch the app now performs a best-effort Ollama warmup itself. If the configured URL is the default local HTTP endpoint, koom will try to start `ollama serve` automatically before giving up. Missing Ollama or a missing model no longer blocks app launch; the app logs the issue, surfaces a small status warning, and skips auto-title work until Ollama becomes available again.

`npm run doctor` still has an "Auto-title (Ollama)" section that verifies Ollama is reachable and the configured model has been pulled. Those checks remain non-fatal so the rest of the doctor sweep still runs.

## Thumbnail generation

Each completed recording also gets a best-effort JPEG thumbnail generated locally on the macOS client. This stays intentionally simple: no queue, no worker, no background cloud media pipeline.

Stages, all on the macOS client:

1. **Extract.** `AVAssetImageGenerator` reads a still frame from the finalized MP4 and encodes it as JPEG. No `ffmpeg`, no full-file re-download from R2, and no mutation of the source recording.
2. **Upload.** The client sends that JPEG to `PUT /api/admin/recordings/[id]/thumbnail`.
3. **Store.** The web backend writes the sidecar object to Cloudflare R2 at `recordings/{id}/thumbnail-v1.jpg`.
4. **Render.** Admin/public recording payloads expose `thumbnailUrl`, and list views use that image first, falling back to `videoUrl#t=0.1` if the sidecar JPEG is missing.

Like auto-titling, thumbnail generation is best-effort. A thumbnail failure never blocks the MP4 upload, never prevents the share URL from opening, and never deletes or mutates the local recording.
