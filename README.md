# koom

[![CI](https://github.com/akurilin/koom/actions/workflows/ci.yml/badge.svg)](https://github.com/akurilin/koom/actions/workflows/ci.yml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/akurilin/koom)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Next.js 16](https://img.shields.io/badge/Next.js-16-000000?logo=next.js&logoColor=white)](https://nextjs.org)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![style: prettier](https://img.shields.io/badge/style-prettier-ff69b4.svg)](https://prettier.io)
[![lint: eslint](https://img.shields.io/badge/lint-eslint-4B32C3.svg)](https://eslint.org)

`koom` is a self-deployable, Loom-style screen recorder for a single user. You record locally in the macOS app, the finished MP4 auto-uploads to storage you own, and you get a shareable watch URL that opens in any browser. No per-seat SaaS subscription, no third party holding your videos, and a small, flat hosting bill at personal scale.

The problem it solves: Loom is great, but you don't actually own your recordings, you pay a monthly subscription, and the videos live on someone else's infrastructure that can be deprecated, paywalled, or taken down. koom keeps the same core loop — record, auto-upload, share a link — but the bytes sit in your Cloudflare R2 bucket, your Next.js app on Render serves the watch page, and the whole stack is narrow enough to fit in your head.

## Highlights

Features koom is particularly proud of:

- **Share-link watch pages.** Anyone with the URL can watch at `/r/[id]` in the browser, no account needed. `?t=` deep-linking lands the viewer on an exact moment.
- **Timestamped comments.** Viewers drop comments anchored to the exact second in the timeline. Anonymous viewers get a stable `koom-commenter` UUID cookie so they can delete their own comments without signing up; admins can reply under the same thread and moderate.
- **Word-level transcripts.** Every recording gets a Loom-style clickable transcript alongside the video. Words highlight and auto-scroll as the video plays; clicking any word seeks the player. Transcription happens on-device via WhisperKit — the audio never leaves the machine.
- **Private auto-titles.** The same WhisperKit pass feeds the transcript to a model running through the bundled llama.cpp runtime, which generates a short, descriptive title. No cloud API, provider install, or subscription.
- **Local thumbnails.** Each recording gets a JPEG still generated on-device and uploaded alongside the video, so list views are lightweight instead of seeking into the MP4.
- **Predictable recording output.** Capture is H.264 MP4 at a fixed 30 fps, with aspect-preserving 720p, 1080p (default), and 4K bounds. Optional local ffmpeg processing normalizes narration and keeps an optimized re-encode only when it saves at least 10%.
- **Crash recovery.** Force-quit, crash, or lose power mid-recording and the next app launch offers to resume, finish, or discard the in-progress session. Recordings are written as a chain of complete ~30-second segment files while capture runs, so a crash loses at most the segment being written.
- **Inline admin rename.** Admins can click the title on the watch page to rename a recording inline — no separate admin form.
- **Light/dark/system theme.** The watch page and admin UI respect `prefers-color-scheme` and offer a manual toggle that persists to `localStorage` with no flash of the wrong theme on first paint.
- **Zero-egress storage.** Cloudflare R2 has no bandwidth fees, so cost stays flat no matter how much the links get shared.
- **One-click hosting via a Render Blueprint.** `render.yaml` declares the web service and its Postgres database; migrations run automatically before each deploy goes live.
- **Guided self-hosting via `npm run doctor`.** The default doctor validates operator prerequisites and external services: R2 with Range-request checks, the Render Postgres schema, the Render web service and its environment, and the desktop runtime. Contributors use `npm run doctor:dev` for the local Docker Postgres and development configuration, while `npm run doctor:all` runs the complete diagnostic sweep.
- **Deliberately narrow scope.** Single-tenant, one admin secret, no teams, no server-side transcoding. The whole stack fits in your head.

Some of these features have longer write-ups — see [Deeper reading](#deeper-reading) at the bottom.

## Architecture

koom is a small monorepo split by runtime:

| Component  | Stack                                            | Role                                                                       |
| ---------- | ------------------------------------------------ | -------------------------------------------------------------------------- |
| `client/`  | Swift 6, SwiftUI, AVFoundation, ScreenCaptureKit | Records, uploads, transcribes, and generates titles locally                |
| `web/`     | Next.js 16 (App Router), TypeScript, React 19    | Public watch pages, admin UI, backend API routes                           |
| `db/`      | Hand-written SQL migrations, applied via `pg`    | `recordings`, `comments`, `commenters` tables (no ORM)                     |
| `scripts/` | TypeScript, run through `tsx`                    | Operator tooling — `doctor`, `db`, `r2:setup`, `r2:orphans`, `render:sync` |

Deployment targets:

- **Web tier:** Render web service (`koom-web` in [`render.yaml`](render.yaml))
- **Metadata:** Render Postgres (`koom-db` in [`render.yaml`](render.yaml)), reached only by the web service over Render's private network
- **Video + CDN:** Cloudflare R2 with its built-in CDN
- **Local development:** a project-local Postgres container ([`docker-compose.yml`](docker-compose.yml)) with its own `koom` database
- **Auth:** a single deployment-wide admin secret; browsers use a signed cookie, the desktop client uses `Authorization: Bearer`. Anonymous commenters are tracked by a plain UUID cookie.

### How a recording flows end to end

1. The macOS client records at a fixed 30 fps and the selected resolution to `~/Movies/koom/prod/koom_YYYY-MM-DD_HH-mm-ss.mp4`. It keeps the local copy permanently and, when ffmpeg is available, applies best-effort narration normalization plus optional size optimization before upload.
2. On completion, the client asks `POST /api/admin/uploads/init` for a presigned R2 `PUT` URL and writes a `pending` row to Postgres.
3. The client `PUT`s the file straight to R2 — bytes never flow through the web service.
4. In parallel, on-device post-upload processing kicks off: WhisperKit produces a word-level transcript, a model hosted by the bundled llama.cpp runtime turns that transcript into a short title, and `AVAssetImageGenerator` grabs a JPEG thumbnail. Nothing leaves the machine except the derived artifacts you choose to upload back into your own stack.
5. `POST /api/admin/uploads/complete` confirms the object landed, flips the row to `complete`, and returns the share URL. The client then `PATCH`es the title onto the row and uploads the transcript + thumbnail as sidecar artifacts in R2.
6. The client copies the share URL to the clipboard and opens it. Anyone with the link can watch, read the clickable transcript, leave timestamped comments, and (if admin) rename the recording inline.

The Next.js app holds all R2 and Postgres credentials. The desktop client only knows the web URL and the admin secret; every interaction with R2 is gated by short-lived presigned URLs.

## Requirements

### Must-haves

- **macOS 26 Tahoe or later** — the recorder is a native SwiftUI + ScreenCaptureKit app, Mac-only for now.
- **A [Cloudflare](https://dash.cloudflare.com) account with R2 enabled** — stores the actual video files and serves them via R2's built-in CDN. Cloudflare requires a payment method on file to enable R2 even on the free tier, but at koom's scale you'll stay well inside the free quota.
- **A [Render](https://render.com) account** — hosts both the Next.js web app (watch pages, admin UI, backend API routes) and the Postgres database for the `recordings`, `comments`, and `commenters` tables, from the Blueprint in [`render.yaml`](render.yaml). The Blueprint uses Render's smallest _paid_ instance types: free Render Postgres is deleted 30 days after creation plus a 14-day grace period, and free web services sleep after 15 idle minutes and can't run the pre-deploy migration step. See [Render pricing](https://render.com/pricing).
- **A GitHub repository** holding your copy of koom — Render deploys from it.
- **Node.js 24.14.1+ and npm 11.11.0+** — pinned in `.nvmrc` and `package.json` engines. Needed for the web app and the operator scripts.
- **Screen Recording, Camera, and Microphone permissions** on macOS — granted at first launch. Camera is only needed if you use the face overlay; microphone is only needed if you want narration + transcripts + auto-titles.

### Nice-to-haves

- **A local title model** — koom downloads the recommended ~563 MB Qwen model in the background on first launch. Local title generation is optional: recording and transcription keep working while it downloads or when it is disabled. Settings lets you enable, choose, redownload, or remove any model in the curated list.
- **`brew install ffmpeg`** — enables best-effort narration loudness normalization and optional recording optimization. Without it, koom keeps and uploads the original H.264 MP4.
- **Docker Desktop** — runs the local Postgres container via `npm run db:start`. It is required for local development and `npm run doctor:dev`, but not for the default self-host/operator doctor.
- **`brew install gitleaks shellcheck`** — so the pre-commit hook can run locally with the same checks CI runs.

## Configuration model

koom has two environment files — keep this in mind while reading the setup instructions below:

- **`web/.env.local`** holds everything needed for local development, plus the handful of shared secrets that are the same in local and production (R2 credentials, `KOOM_ADMIN_SECRET`). `DATABASE_URL` here is **always** the local Docker Postgres.
- **`web/.env.prod.local`** holds values used only to inspect production from your dev machine: `RENDER_API_KEY`, `RENDER_SERVICE_ID`, and `RENDER_DATABASE_URL` (koom-db's external connection string). Nothing in it is deployed.
- **Production configuration lives in Render.** [`render.yaml`](render.yaml) wires `DATABASE_URL` to the database's internal connection string, and Render prompts once for the R2 values and `KOOM_ADMIN_SECRET` when you create the Blueprint. Share URLs use the service's `onrender.com` URL unless you set `KOOM_PUBLIC_BASE_URL` (see [Custom domain](#custom-domain)).

Both files are gitignored. Every doctor mode bootstraps `web/.env.local` from its template when needed; the operator and all modes also bootstrap `web/.env.prod.local`. The dev doctor deliberately leaves the production-only file alone.

## Getting started

### Self-hosting

```bash
# 1. Clone the repo and install Node dependencies (npm workspaces, husky, etc.)
git clone https://github.com/akurilin/koom.git
cd koom
npm install

# 2. Bootstrap the env files. Running the doctor creates both
#    web/.env.local and web/.env.prod.local from their .example
#    templates, then reports exactly what's missing.
npm run doctor
```

The first operator doctor run bootstraps both env files and fails loudly because they are empty. Work through each blocked check in order:

1. **Cloudflare R2.** Create a Cloudflare account, enable R2 (requires a card — free tier is plenty), copy your Account ID, and mint an API token with `Workers R2 Storage → Edit` + `User API Tokens → Edit` permissions. Paste the token and account ID into `web/.env.local`. The file's comments walk through every click. Then run `npm run r2:setup` — it creates the bucket, generates the runtime S3 credentials, configures CORS, and fills in the remaining `R2_*` values for you.
2. **`KOOM_ADMIN_SECRET`.** Generate with `openssl rand -hex 32` and paste into `web/.env.local`. Same value is used for local dev and production — the desktop client uses it as a bearer token, the web admin login uses it as a password.
3. **Render.** Push your koom repo to GitHub, then in the Render dashboard choose **New → Blueprint** and select the repo. Render reads [`render.yaml`](render.yaml), creates the `koom-db` Postgres instance and the `koom-web` service, and prompts once for `KOOM_ADMIN_SECRET` and the five `R2_*` values — paste them from `web/.env.local`. The first deploy builds the app, applies `db/migrations/` in its pre-deploy step, and serves koom at `https://koom-web.onrender.com` (or the variant Render assigns). Enter that URL as the backend URL in the desktop app's Settings.
4. **Operator credentials.** Fill in `web/.env.prod.local`: create an API key under Render → Account Settings → API Keys (`RENDER_API_KEY`), copy the `srv-...` id from the koom-web service URL (`RENDER_SERVICE_ID`), and copy koom-db's **External Database URL** from its Connect menu (`RENDER_DATABASE_URL`).
5. **macOS code-signing identity.** `npm run app:codesign` creates a stable local identity so rebuilds don't break Keychain trust.
6. **Rerun `npm run doctor`** until the self-host/operator report is ready.

Install the signed desktop client when the operator doctor is happy:

```bash
npm run app:install
```

### Custom domain

To serve koom from your own hostname instead of `onrender.com`:

1. In Render, open koom-web → **Settings → Custom Domains** and add the hostname (e.g. `koom.example.com`). Render shows the DNS record it expects.
2. At your DNS provider, create that record — for a subdomain, a `CNAME` from the subdomain to the service's `onrender.com` hostname. If your domain lives at Squarespace (including domains migrated from Google Domains), that's **Domains → your domain → DNS → Custom records**. Remove any old record for the same hostname that pointed at a previous host first.
3. Wait for Render to verify the domain and issue its certificate.
4. Set `KOOM_PUBLIC_BASE_URL=https://koom.example.com` on koom-web (**Environment**) so new share links use your hostname, then update the backend URL in the desktop app's Settings to match. Existing links keep working on `onrender.com`.

### Local development

Contributors can validate and run the local stack without any access to the Render deployment. Postgres runs in a project-local Docker container with its own `koom` database:

```bash
# Bootstrap and inspect only local-development requirements
npm run doctor:dev

# Start the local Postgres container and apply the migrations
npm run db:start
npm run db:reset

# Create the stable local signing identity
npm run app:codesign

# Confirm the development environment
npm run doctor:dev
```

The local web app currently uses the configured R2 bucket, so development still requires the R2 credentials and `KOOM_ADMIN_SECRET` in `web/.env.local`. Once the dev doctor is ready, start the two application processes:

```bash
npm run dev -w web
npm run app:run
```

To exercise model onboarding without changing the normal client profile, launch
the app with a fresh disposable profile:

```bash
npm run app:run:onboarding
```

Every invocation creates a unique directory under macOS's per-user temporary
directory. Client preferences remain in memory for that run, while downloaded
models, logs, recordings, recovery data, and development admin secrets are
written beneath the temporary profile. The directory is intentionally left for
macOS to clean up later. This replays Koom's onboarding state but retains the
app's existing macOS privacy permissions because the bundle identity is
unchanged.

The root `package.json` is the primary interface for repository tasks. The
implementations and retained compatibility entry points are described in
[`scripts/README.md`](scripts/README.md).

## Doctor script

The doctor has one implementation with three focused entry points:

| Command              | Purpose                                                     |
| -------------------- | ----------------------------------------------------------- |
| `npm run doctor`     | Self-host/operator readiness; does not require Docker       |
| `npm run doctor:dev` | Local development readiness; does not require Render access |
| `npm run doctor:all` | Complete diagnostic sweep across both paths                 |

R2 connectivity, the admin secret, the local-title packaging recipe, and desktop code signing are shared checks. The dev mode adds localhost configuration plus local Postgres schema and round-trip checks. The operator mode adds Render Postgres connectivity and schema checks (read-only), plus the Render web service's reachability, environment drift, and public URL.

Each mode executes only its relevant sections and derives its exit code from those checks. A stopped local Docker stack therefore cannot fail `npm run doctor`, and missing Render credentials cannot fail `npm run doctor:dev`. All modes are safe to rerun: R2 test objects and local Postgres test rows are cleaned up.

### Render sync

`npm run render:sync` compares the environment variables set on the koom-web Render service against the local sources of truth in `web/.env.local` and reports each one as `in sync`, `drift`, `missing`, or `unresolvable` (the local source is unset). `DATABASE_URL` is only checked for presence, because its value is wired up inside Render by `render.yaml`. The command is read-only and never prints values; fix drift in Render → koom-web → Environment. The doctor runs the same comparison as one aggregate check in its Render section.

### Database migrations

Migrations are plain SQL files in [`db/migrations/`](db/migrations), applied in filename order by [`scripts/db.ts`](scripts/db.ts), which records each one in a `schema_migrations` table:

| Command                           | Purpose                                                       |
| --------------------------------- | ------------------------------------------------------------- |
| `npm run db:start` / `db:stop`    | Start or stop the local Postgres container                    |
| `npm run db:migrate`              | Apply pending migrations to `DATABASE_URL` (default: local)   |
| `npm run db:reset`                | Local only: wipe the public schema and reapply all migrations |
| `npm run db:migration:new <slug>` | Scaffold a timestamped migration file                         |

On Render, `db:migrate` runs as koom-web's pre-deploy command, so a merged migration is applied before the release that needs it starts serving traffic.

A pre-commit hook (husky + lint-staged) runs ESLint, Prettier, `swift format`, ShellCheck, and gitleaks against staged changes before any commit lands. The same checks run in GitHub Actions on push and pull requests, plus a full-history gitleaks scan.

The desktop app writes persistent logs to `~/Library/Logs/koom/koom.log` (with one rotated `koom.previous.log`). From the app itself, **Troubleshooting → Reveal Logs in Finder** jumps straight to that directory.
