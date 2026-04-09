# koom

[![CI](https://github.com/akurilin/koom/actions/workflows/ci.yml/badge.svg)](https://github.com/akurilin/koom/actions/workflows/ci.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/akurilin/koom)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Next.js 16](https://img.shields.io/badge/Next.js-16-000000?logo=next.js&logoColor=white)](https://nextjs.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![style: prettier](https://img.shields.io/badge/style-prettier-ff69b4.svg)](https://prettier.io)
[![lint: eslint](https://img.shields.io/badge/lint-eslint-4B32C3.svg)](https://eslint.org)

`koom` is a self-deployable, Loom-style screen recorder for a single user. You record locally in the macOS app, the finished MP4 auto-uploads to storage you own, and you get a shareable watch URL that opens in any browser. No SaaS subscription, no third party holding your videos, and typically **$0–5/month** at personal scale.

## Why koom

Loom is great, but you don't actually own your recordings, you pay monthly, and the videos live on someone else's infrastructure. koom is the same core loop — record, auto-upload, share a link — but:

- **You own the bytes.** Videos sit in your Cloudflare R2 bucket. No vendor can deprecate, paywall, or delete them.
- **Zero-egress storage.** R2 has no bandwidth fees, so cost stays flat no matter how much the links get shared.
- **Deliberately narrow scope.** Single-tenant, one admin secret, no teams, no comments, no stored transcripts, no search beyond a simple list. The whole stack fits in your head.
- **Cheap steady state.** Vercel Hobby + Supabase free tier + R2 free tier. The only variable cost is R2 storage above 10 GB.
- **Private auto-titles.** Recordings get a short descriptive title generated locally via WhisperKit + Ollama — the audio never leaves your machine, and the feature is an opt-out, not an extra subscription.

v1 intentionally leaves a lot out: no accounts, no comments, no stored transcripts or captions, no transcoding, no custom domains. See [`docs/monorepo-backend-plan.md`](docs/monorepo-backend-plan.md) for the full decision record.

## Architecture

koom is a small monorepo split by runtime:

| Component   | Stack                                            | Role                                                           |
| ----------- | ------------------------------------------------ | -------------------------------------------------------------- |
| `client/`   | Swift 6, SwiftUI, AVFoundation, ScreenCaptureKit | Records the screen, uploads the finished file                  |
| `web/`      | Next.js 16 (App Router), TypeScript, React 19    | Public watch pages, admin UI, backend API routes               |
| `supabase/` | Hand-written SQL migrations, managed via `pg`    | Single `recordings` metadata table (no ORM)                    |
| `scripts/`  | TypeScript, run through `tsx`                    | R2 provisioning (`r2:setup`) and stack verification (`doctor`) |

Deployment targets:

- **Web tier:** Vercel Hobby
- **Metadata:** Supabase Postgres (used purely as a Postgres provider — no Supabase Auth, no Supabase Storage)
- **Video + CDN:** Cloudflare R2 with its built-in CDN
- **Auth:** a single deployment-wide admin secret; browsers use a signed cookie, the desktop client uses `Authorization: Bearer`

### How a recording flows end to end

1. The macOS client records to `~/Movies/koom/koom_YYYY-MM-DD_HH-mm-ss.mp4` and keeps the local copy permanently. Recording is staged through a fragmented MP4 session so a crash mid-capture can be recovered on the next launch (see [Crash recovery](#crash-recovery)).
2. On completion, the client asks `POST /api/admin/uploads/init` for a presigned R2 `PUT` URL and writes a `pending` row to Postgres.
3. The client `PUT`s the file straight to R2 — bytes never flow through Vercel.
4. In parallel with step 3, the local auto-titler extracts the mic track via `AVAssetReader`, transcribes it in-process with WhisperKit, and asks a local Ollama model for a short title. Nothing leaves the machine, and every stage is best-effort — a missing mic or an Ollama that isn't running just leaves the title blank.
5. `POST /api/admin/uploads/complete` `HEAD`s the object to confirm it landed, flips the row to `complete`, and returns the share URL. If the auto-titler produced a title by then, the client `PATCH`es it onto the row.
6. The client copies the share URL to the clipboard and opens it. Anyone with the link can watch at `/r/[id]` (with `?t=` timestamp deep-linking).

The Next.js app holds all R2 and Postgres credentials. The desktop client only knows the web URL and the admin secret; every interaction with R2 is gated by short-lived presigned URLs.

## Repository layout

```text
client/                  macOS Swift package (recorder + uploader)
  Sources/koom/          SwiftUI app, ScreenCaptureKit, upload pipeline
  Package.swift
  scripts/               build-app.sh, run.sh
web/                     Next.js app (frontend + backend)
  app/                   App Router pages
    r/[id]/              public watch page
    app/                 admin UI (login, recordings list)
    api/public/          public JSON endpoints
    api/admin/           admin JSON endpoints (session, uploads, recordings)
  lib/
    db/                  thin `pg` Pool + parameterized query helpers
    r2/                  S3-compatible R2 client + presigning
    auth/                admin session + bearer validation
  tests/                 Vitest integration + Playwright E2E
supabase/
  migrations/            hand-written SQL, applied via the Supabase CLI
  config.toml            local stack configuration
scripts/
  doctor.ts              read-only verification sweep across the full stack
  r2-orphans.ts          audit or delete orphaned recording objects in R2
  r2-setup.ts            provisions the production R2 bucket + credentials
  r2-setup-test.ts       provisions the isolated E2E test bucket
  build-app.sh, run.sh   thin wrappers that delegate into client/scripts
docs/
  monorepo-backend-plan.md   architectural decision record
```

## Requirements

- macOS 14+ for the desktop client (bumped from 13 when WhisperKit landed)
- Node.js 20+ for the web app and operator scripts
- A Cloudflare account (R2 free tier is enough to start)
- A Supabase project — or Docker, for the local Supabase stack via `npm run db:start`
- Optional: [Ollama](https://ollama.com) if you want the auto-titler (`brew install ollama && ollama pull gemma4:e4b`). `./scripts/run.sh` now preflights the configured Ollama endpoint, auto-starts `ollama serve` for the default local URL when needed, restarts a stale local `ollama serve` once if warmup fails, and refuses to launch by default if the model still is not ready. Set `KOOM_AUTOTITLE_ENABLED=false` to disable the feature entirely or `KOOM_OLLAMA_REQUIRE_READY=false` to allow a degraded launch.
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

# 5. run the web app
npm run dev -w web

# 6. build and run the macOS client
./scripts/run.sh
```

`npm run doctor` is the authoritative "is this environment actually usable?" check. It's always safe to re-run and exercises the database, R2 credentials, and HTTP range support that browser `<video>` scrubbing depends on.

`npm run r2:orphans` audits the shared R2 bucket for `recordings/{id}/...` objects that no longer have a matching row in the configured database set. It is dry-run by default; add `-- --delete` to remove confirmed orphans, and add `-- --prod-db-url ...` or `-- --prod-env-file ...` when you want to union a production database into the check.

## Development

| Task                               | Command                   |
| ---------------------------------- | ------------------------- |
| Clean rebuildable web caches       | `npm run web:clean`       |
| Lint the web workspace             | `npm run lint`            |
| Check formatting (Prettier)        | `npm run format:check`    |
| Auto-fix formatting                | `npm run format`          |
| Lint Swift sources                 | `npm run swift:lint`      |
| Auto-fix Swift formatting          | `npm run swift:format`    |
| ShellCheck every tracked `.sh`     | `npm run shellcheck`      |
| Audit orphaned R2 recording files  | `npm run r2:orphans`      |
| Web unit + integration tests       | `npm test -w web`         |
| Web end-to-end tests (Playwright)  | `npm run test:e2e -w web` |
| Build the macOS client bundle      | `./scripts/build-app.sh`  |
| Run the macOS client in foreground | `./scripts/run.sh`        |

`npm run web:clean` removes the web workspace's rebuildable artifacts (`web/.next`, `web/node_modules/.vite`, and Playwright/Vitest output directories). It refuses to run while a live `next dev` process still owns the workspace.

A pre-commit hook (husky + lint-staged) runs ESLint, Prettier, `swift format`, ShellCheck, and gitleaks against staged changes before any commit lands. Swift sources use Apple's official `swift-format` (ships with the Swift 6 toolchain) against the repo-level `.swift-format` config. The rest of the checks also run in GitHub Actions on push and pull requests, plus a full-history gitleaks scan.

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

Recordings that otherwise would have stayed untitled get a short descriptive title generated on the same machine that did the recording — no cloud APIs, no third-party telemetry, no server-side worker. The pipeline runs once per recording and every stage is best-effort: any failure (no mic track, Ollama offline, empty transcript) logs a line and leaves the `title` column `NULL`. The upload flow is otherwise untouched.

Stages, all in-process on the macOS client:

1. **Extract.** `AVAssetReader` pulls the mic audio out of the finalized MP4 into 16 kHz mono float PCM. No ffmpeg, no temp files.
2. **Transcribe.** An actor-wrapped `WhisperKit` instance runs the CoreML model against the PCM buffer. The instance is loaded lazily on first use and memoized for the rest of the process, so the ~500 MB model download only happens once (into the standard HuggingFace Hub cache at `~/.cache/huggingface/hub/`).
3. **Summarize.** The transcript is sent to a local Ollama model via `POST http://localhost:11434/api/generate` with `think: false` (important — reasoning-capable models like `gemma4:e4b` otherwise route their output into a separate `thinking` field and return an empty `response`). The client asks for a 4–10 word title and sanitizes it (strips `Title:` prefixes, smart/straight quotes, trailing punctuation, clamps to 10 words).
4. **Persist.** The title is `PATCH`ed onto the `recordings` row via `PATCH /api/admin/recordings/[id]`. Pending rows (upload still in flight) are also allowed to take a title so the auto-titler can land early on fast uploads.

All five environment variables are optional. Defaults are hard-coded in `Autotitler.swift`:

| Variable                    | Default                   | Purpose                                                                                                    |
| --------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `KOOM_AUTOTITLE_ENABLED`    | `true`                    | Set to `false`/`0`/`no`/`off` to skip the pipeline entirely                                                |
| `KOOM_WHISPER_MODEL`        | `openai_whisper-small.en` | Any model WhisperKit publishes on HuggingFace                                                              |
| `KOOM_OLLAMA_URL`           | `http://localhost:11434`  | Ollama HTTP base URL                                                                                       |
| `KOOM_OLLAMA_MODEL`         | `gemma4:e4b`              | Any model you've `ollama pull`ed locally                                                                   |
| `KOOM_OLLAMA_REQUIRE_READY` | `true`                    | Set to `false`/`0`/`no`/`off` to let `./scripts/run.sh` launch in degraded mode when Ollama is unavailable |

`./scripts/run.sh` now performs the stronger local-dev preflight: if `KOOM_AUTOTITLE_ENABLED` is on, it verifies that Ollama is reachable, the configured model is pulled, and the model can answer a tiny warmup request. For the default local URL it will try to start `ollama serve` automatically before giving up, and if the server is reachable but returns a model-load failure it will restart local Ollama once and retry. By default a failed preflight aborts app launch; set `KOOM_OLLAMA_REQUIRE_READY=false` to allow a degraded launch instead.

`npm run doctor` still has an "Auto-title (Ollama)" section that verifies Ollama is reachable and the configured model has been pulled. Those checks remain non-fatal so the rest of the doctor sweep still runs.
