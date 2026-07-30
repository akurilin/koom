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

The problem it solves: Loom is great, but you don't actually own your recordings, you pay a monthly subscription, and the videos live on someone else's infrastructure that can be deprecated, paywalled, or taken down. koom keeps the same core loop — record, auto-upload, share a link — but the bytes sit in your Cloudflare R2 bucket, your Next.js app on Vercel serves the watch page, and the whole stack is narrow enough to fit in your head.

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
- **Guided self-hosting via `npm run doctor`.** The default doctor validates operator prerequisites and external services: R2 with Range-request checks, hosted Supabase, Vercel configuration, and the desktop runtime. Contributors use `npm run doctor:dev` for local Postgres and development configuration, while `npm run doctor:all` runs the complete diagnostic sweep.
- **Deliberately narrow scope.** Single-tenant, one admin secret, no teams, no server-side transcoding, no custom domains. The whole stack fits in your head.

Some of these features have longer write-ups — see [Deeper reading](#deeper-reading) at the bottom.

## Architecture

koom is a small monorepo split by runtime:

| Component   | Stack                                            | Role                                                                 |
| ----------- | ------------------------------------------------ | -------------------------------------------------------------------- |
| `client/`   | Swift 6, SwiftUI, AVFoundation, ScreenCaptureKit | Records, uploads, transcribes, and generates titles locally          |
| `web/`      | Next.js 16 (App Router), TypeScript, React 19    | Public watch pages, admin UI, backend API routes                     |
| `supabase/` | Hand-written SQL migrations, managed via `pg`    | `recordings`, `comments`, `commenters` tables (no ORM)               |
| `scripts/`  | TypeScript, run through `tsx`                    | Operator tooling — `doctor`, `r2:setup`, `r2:orphans`, `vercel:sync` |

Deployment targets:

- **Web tier:** Vercel Hobby
- **Metadata:** Supabase Postgres (used purely as a Postgres provider — no Supabase Auth, no Supabase Storage)
- **Video + CDN:** Cloudflare R2 with its built-in CDN
- **Auth:** a single deployment-wide admin secret; browsers use a signed cookie, the desktop client uses `Authorization: Bearer`. Anonymous commenters are tracked by a plain UUID cookie.

### How a recording flows end to end

1. The macOS client records at a fixed 30 fps and the selected resolution to `~/Movies/koom/prod/koom_YYYY-MM-DD_HH-mm-ss.mp4`. It keeps the local copy permanently and, when ffmpeg is available, applies best-effort narration normalization plus optional size optimization before upload.
2. On completion, the client asks `POST /api/admin/uploads/init` for a presigned R2 `PUT` URL and writes a `pending` row to Postgres.
3. The client `PUT`s the file straight to R2 — bytes never flow through Vercel.
4. In parallel, on-device post-upload processing kicks off: WhisperKit produces a word-level transcript, a model hosted by the bundled llama.cpp runtime turns that transcript into a short title, and `AVAssetImageGenerator` grabs a JPEG thumbnail. Nothing leaves the machine except the derived artifacts you choose to upload back into your own stack.
5. `POST /api/admin/uploads/complete` confirms the object landed, flips the row to `complete`, and returns the share URL. The client then `PATCH`es the title onto the row and uploads the transcript + thumbnail as sidecar artifacts in R2.
6. The client copies the share URL to the clipboard and opens it. Anyone with the link can watch, read the clickable transcript, leave timestamped comments, and (if admin) rename the recording inline.

The Next.js app holds all R2 and Postgres credentials. The desktop client only knows the web URL and the admin secret; every interaction with R2 is gated by short-lived presigned URLs.

## Requirements

### Must-haves

- **macOS 26 Tahoe or later** — the recorder is a native SwiftUI + ScreenCaptureKit app, Mac-only for now.
- **A [Cloudflare](https://dash.cloudflare.com) account with R2 enabled** — stores the actual video files and serves them via R2's built-in CDN. Cloudflare requires a payment method on file to enable R2 even on the free tier, but at koom's scale you'll stay well inside the free quota.
- **A [Supabase](https://supabase.com) project** — used purely as a hosted Postgres provider for the `recordings`, `comments`, and `commenters` tables. Supabase Auth, Storage, and PostgREST are not used and are [explicitly locked down](CLAUDE.md#database-access-model-supabase-lockdown). The free tier is plenty.
- **A [Vercel](https://vercel.com) account** — deploys the Next.js web app (watch pages, admin UI, backend API routes). Vercel Hobby is plenty.
- **Node.js 24.14.1+ and npm 11.11.0+** — pinned in `.nvmrc` and `package.json` engines. Needed for the web app and the operator scripts.
- **Screen Recording, Camera, and Microphone permissions** on macOS — granted at first launch. Camera is only needed if you use the face overlay; microphone is only needed if you want narration + transcripts + auto-titles.

### Nice-to-haves

- **A local title model** — koom downloads the recommended ~563 MB Qwen model in the background on first launch. Local title generation is optional: recording and transcription keep working while it downloads or when it is disabled. Settings lets you enable, choose, redownload, or remove any model in the curated list.
- **`brew install ffmpeg`** — enables best-effort narration loudness normalization and optional recording optimization. Without it, koom keeps and uploads the original H.264 MP4.
- **Docker Desktop** — lets you run the local Supabase stack via `npm run db:start`. It is required for `npm run doctor:dev`, but not for the default self-host/operator doctor.
- **`brew install gitleaks shellcheck`** — so the pre-commit hook can run locally with the same checks CI runs.

## Configuration model

koom has two environment files — keep this in mind while reading the setup instructions below:

- **`web/.env.local`** holds everything needed for local development, plus the handful of shared secrets that are the same in local and production (R2 credentials, `KOOM_ADMIN_SECRET`). `DATABASE_URL` here is **always** the local Supabase stack.
- **`web/.env.prod.local`** holds values used only to validate and deploy to production from your dev machine (currently `VERCEL_TOKEN` and `VERCEL_PROJECT_ID`). A future `npm run vercel:sync` will read this file to push env vars into Vercel in one command.
- **The production Postgres URL is never stored in either file.** It's derived live from the Supabase CLI link state (`supabase/.temp/`) after you run `supabase link --project-ref=…`. The doctor script reads those files directly and uses `SUPABASE_DB_PASSWORD` from `.env.local` for authentication. No swapping, no duplication, no drift.

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
3. **Hosted Supabase project.** Create a project at supabase.com, then link the repo to it:
   ```bash
   npx -y supabase@2.87.2 login
   npx -y supabase@2.87.2 link --project-ref=<your-project-ref>
   ```
   After linking, paste the project's database password into `SUPABASE_DB_PASSWORD` in `web/.env.local` (find it at Project Settings → Database → Database password), then run `npm run db:push` to apply the committed migrations. The doctor will now be able to connect to your production Postgres live.
4. **Vercel.** Push the koom repo to GitHub and import it at [vercel.com/new](https://vercel.com/new). In the Vercel project settings → Environment Variables, paste the values that apply in production: `DATABASE_URL` (your hosted Supabase pooler URL, from Project Settings → Database → Connection string), `R2_*`, `KOOM_PUBLIC_BASE_URL` (your Vercel URL), and `KOOM_ADMIN_SECRET`. Then mint a Vercel token at [vercel.com/account/tokens](https://vercel.com/account/tokens), grab the project ID from Vercel → Settings → General → Project ID, and paste both into `web/.env.prod.local`.
5. **macOS code-signing identity.** `npm run app:codesign` creates a stable local identity so rebuilds don't break Keychain trust.
6. **Rerun `npm run doctor`** until the self-host/operator report is ready.

Install the signed desktop client when the operator doctor is happy:

```bash
npm run app:install
```

### Local development

Contributors can validate and run the local stack without configuring Vercel or linking a hosted Supabase project:

```bash
# Bootstrap and inspect only local-development requirements
npm run doctor:dev

# Start local Supabase and apply the migrations
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

| Command              | Purpose                                                           |
| -------------------- | ----------------------------------------------------------------- |
| `npm run doctor`     | Self-host/operator readiness; does not require Docker             |
| `npm run doctor:dev` | Local development readiness; does not require Vercel or a DB link |
| `npm run doctor:all` | Complete diagnostic sweep across both paths                       |

R2 connectivity, the admin secret, the local-title packaging recipe, and desktop code signing are shared checks. The dev mode adds localhost configuration plus local Postgres schema and round-trip checks. The operator mode adds hosted Supabase connectivity plus Vercel reachability and environment drift.

Each mode executes only its relevant sections and derives its exit code from those checks. A stopped local Docker stack therefore cannot fail `npm run doctor`, and missing Vercel credentials cannot fail `npm run doctor:dev`. All modes are safe to rerun: R2 test objects and local Postgres test rows are cleaned up.

### Vercel sync

`npm run vercel:sync` compares every env var configured on the Vercel project against the local sources of truth (`web/.env.local`, the Supabase CLI link state, and the Vercel project's primary domain) and reports per-variable drift. It's currently **dry-run only** — it never writes to Vercel — so it's safe to run whenever you want to audit the production configuration.

Each expected variable falls into one of six buckets: `in-sync`, `drift` (local and Vercel disagree), `missing-on-vercel`, `opaque` (Vercel stores the variable as `sensitive`, which cannot be read back through the API — a future `--write` mode would unconditionally overwrite these), `unknown` (extra variable on Vercel that koom doesn't manage — ignored), or `unresolvable` (the local source for the desired value is missing, e.g. `SUPABASE_DB_PASSWORD` unset). The doctor runs the same comparison as an aggregate check in its Vercel section and surfaces drift as a warning with the offending keys, so you don't need to remember to run the sync command manually — just notice when the doctor tells you to. A future `--write` mode will apply the detected changes in one shot.

A pre-commit hook (husky + lint-staged) runs ESLint, Prettier, `swift format`, ShellCheck, and gitleaks against staged changes before any commit lands. The same checks run in GitHub Actions on push and pull requests, plus a full-history gitleaks scan.

## Deeper reading

Longer-form write-ups of individual subsystems live in [`docs/`](docs/):

- [`docs/recording-output.md`](docs/recording-output.md) — codec, bitrate heuristic, and approximate file sizes produced by the macOS client.
- [`docs/crash-recovery.md`](docs/crash-recovery.md) — how segment rollover and the session manifest keep a recording alive across force-quits and crashes.
- [`docs/post-upload-processing.md`](docs/post-upload-processing.md) — the on-device pipeline for auto-titles, word-level transcripts, and thumbnails.
- [`docs/monorepo-backend-plan.md`](docs/monorepo-backend-plan.md) — the original architectural decision record for the monorepo split.
- [`CLAUDE.md`](CLAUDE.md) — working rules, migration workflow, and the Supabase lockdown model used by every public table in the database.

The desktop app writes persistent logs to `~/Library/Logs/koom/koom.log` (with one rotated `koom.previous.log`). From the app itself, **Troubleshooting → Reveal Logs in Finder** jumps straight to that directory.
