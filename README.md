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
- **Private auto-titles.** The same WhisperKit pass feeds the transcript to a local Ollama model, which generates a short, descriptive title. No cloud API, no subscription.
- **Local thumbnails.** Each recording gets a JPEG still generated on-device and uploaded alongside the video, so list views are lightweight instead of seeking into the MP4.
- **Crash recovery.** Force-quit, crash, or lose power mid-recording and the next app launch offers to resume, finish, or discard the in-progress session. Bytes flushed before the crash stay playable without a clean stop.
- **Inline admin rename.** Admins can click the title on the watch page to rename a recording inline — no separate admin form.
- **Light/dark/system theme.** The watch page and admin UI respect `prefers-color-scheme` and offer a manual toggle that persists to `localStorage` with no flash of the wrong theme on first paint.
- **Zero-egress storage.** Cloudflare R2 has no bandwidth fees, so cost stays flat no matter how much the links get shared.
- **Deliberately narrow scope.** Single-tenant, one admin secret, no teams, no transcoding, no custom domains. The whole stack fits in your head.

Some of these features have longer write-ups — see [Deeper reading](#deeper-reading) at the bottom.

## Architecture

koom is a small monorepo split by runtime:

| Component   | Stack                                            | Role                                                      |
| ----------- | ------------------------------------------------ | --------------------------------------------------------- |
| `client/`   | Swift 6, SwiftUI, AVFoundation, ScreenCaptureKit | Records the screen, uploads the file, transcribes locally |
| `web/`      | Next.js 16 (App Router), TypeScript, React 19    | Public watch pages, admin UI, backend API routes          |
| `supabase/` | Hand-written SQL migrations, managed via `pg`    | `recordings`, `comments`, `commenters` tables (no ORM)    |
| `scripts/`  | TypeScript, run through `tsx`                    | Operator tooling — `r2:setup`, `doctor`, `r2:orphans`     |

Deployment targets:

- **Web tier:** Vercel Hobby
- **Metadata:** Supabase Postgres (used purely as a Postgres provider — no Supabase Auth, no Supabase Storage)
- **Video + CDN:** Cloudflare R2 with its built-in CDN
- **Auth:** a single deployment-wide admin secret; browsers use a signed cookie, the desktop client uses `Authorization: Bearer`. Anonymous commenters are tracked by a plain UUID cookie.

### How a recording flows end to end

1. The macOS client records to `~/Movies/koom/koom_YYYY-MM-DD_HH-mm-ss.mp4` and keeps the local copy permanently.
2. On completion, the client asks `POST /api/admin/uploads/init` for a presigned R2 `PUT` URL and writes a `pending` row to Postgres.
3. The client `PUT`s the file straight to R2 — bytes never flow through Vercel.
4. In parallel, on-device post-upload processing kicks off: WhisperKit produces a word-level transcript, a local Ollama model turns that transcript into a short title, and `AVAssetImageGenerator` grabs a JPEG thumbnail. Nothing leaves the machine except the derived artifacts you choose to upload back into your own stack.
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

- **[Ollama](https://ollama.com)** — enables local auto-title generation. Install with `brew install ollama && ollama pull gemma4:e4b`. The app will auto-start `ollama serve` on first use and is fine running without it — auto-title and transcript extraction gracefully degrade when Ollama is unreachable.
- **Docker Desktop** — lets you run the local Supabase stack via `npm run db:start` instead of developing directly against a hosted Supabase project. Recommended if you plan to touch migrations.
- **`brew install gitleaks shellcheck`** — so the pre-commit hook can run locally with the same checks CI runs.

## Configuration model

koom has two environment files — keep this in mind while reading the setup instructions below:

- **`web/.env.local`** holds everything needed for local development, plus the handful of shared secrets that are the same in local and production (R2 credentials, `KOOM_ADMIN_SECRET`). `DATABASE_URL` here is **always** the local Supabase stack.
- **`web/.env.prod.local`** holds values used only to validate and deploy to production from your dev machine (currently `VERCEL_TOKEN` and `VERCEL_PROJECT_ID`). A future `npm run vercel:sync` will read this file to push env vars into Vercel in one command.
- **The production Postgres URL is never stored in either file.** It's derived live from the Supabase CLI link state (`supabase/.temp/`) after you run `supabase link --project-ref=…`. The doctor script reads those files directly and uses `SUPABASE_DB_PASSWORD` from `.env.local` for authentication. No swapping, no duplication, no drift.

Both files are gitignored and auto-bootstrapped from their `.example` templates the first time you run the doctor, so you usually won't copy them by hand.

## Getting started

First-time setup from a clean machine.

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

The first doctor run will fail loudly because the env files are empty. Work through each blocked check in order:

1. **Cloudflare R2.** Create a Cloudflare account, enable R2 (requires a card — free tier is plenty), copy your Account ID, and mint an API token with `Workers R2 Storage → Edit` + `User API Tokens → Edit` permissions. Paste the token and account ID into `web/.env.local`. The file's comments walk through every click. Then run `npm run r2:setup` — it creates the bucket, generates the runtime S3 credentials, configures CORS, and fills in the remaining `R2_*` values for you.
2. **Local Supabase.** Install Docker Desktop, then `npm run db:start` + `npm run db:reset` to boot the local stack and apply migrations.
3. **`KOOM_ADMIN_SECRET`.** Generate with `openssl rand -hex 32` and paste into `web/.env.local`. Same value is used for local dev and production — the desktop client uses it as a bearer token, the web admin login uses it as a password.
4. **Hosted Supabase project (for production).** Create a project at supabase.com, then link the repo to it:
   ```bash
   npx -y supabase@2.87.2 login
   npx -y supabase@2.87.2 link --project-ref=<your-project-ref>
   ```
   After linking, paste the project's database password into `SUPABASE_DB_PASSWORD` in `web/.env.local` (find it at Project Settings → Database → Database password). The doctor will now be able to connect to your production Postgres live.
5. **Vercel.** Push the koom repo to GitHub and import it at [vercel.com/new](https://vercel.com/new). In the Vercel project settings → Environment Variables, paste the values that apply in production: `DATABASE_URL` (your hosted Supabase pooler URL, from Project Settings → Database → Connection string), `R2_*`, `KOOM_PUBLIC_BASE_URL` (your Vercel URL), and `KOOM_ADMIN_SECRET`. Then mint a Vercel token at [vercel.com/account/tokens](https://vercel.com/account/tokens), grab the project ID from Vercel → Settings → General → Project ID, and paste both into `web/.env.prod.local`. (We plan to automate this step with `npm run vercel:sync` in a later round.)
6. **macOS code-signing identity.** `./scripts/setup-dev-codesign.sh` creates a stable local identity so rebuilds don't break Keychain trust.
7. **Rerun `npm run doctor`** until both readiness tracks are green.

Once the doctor is happy, start the stack:

```bash
# Web app
npm run dev -w web

# macOS client (development build)
./scripts/run.sh

# Install the signed release app into /Applications when you're ready
./scripts/install-app.sh
```

## Doctor script

`npm run doctor` is the single "is this environment actually usable?" check. It's safe to re-run any time. It produces a readiness report that tells you separately whether local development is ready and whether production deployment is ready — and exactly what's missing if either isn't.

It exercises:

- **Environment variables** — every required and optional var in `web/.env.local` and `web/.env.prod.local`, with bootstrap-from-template if either file is missing.
- **Cloudflare R2** — credentials work, test PUT/HEAD/GET round-trips, public URL serves the bytes, and crucially `Range` requests return `HTTP 206` (the load-bearing assumption for video scrubbing). Counts toward both tracks because the same bucket is shared between local and production.
- **Local Postgres** — connectivity, schema matches migrations (`recordings`, `comments`, `commenters`), and a round-trip INSERT/SELECT/DELETE on `recordings`.
- **Remote Supabase** — verifies the Supabase CLI is installed, that `supabase link` has been run against a hosted project, and that the cached pooler URL + `SUPABASE_DB_PASSWORD` can actually connect to the remote Postgres with a `SELECT 1`. The doctor does **not** validate whether migrations have been applied to the remote DB — just that you have something you can migrate against. No test rows are written to production.
- **Ollama (auto-title)** — server is reachable and the configured model is pulled (non-fatal).
- **Desktop code signing** — local dev codesign identity is present and usable on macOS.
- **Vercel** — if `VERCEL_TOKEN` and `VERCEL_PROJECT_ID` are set in `web/.env.prod.local`, the project is reachable and the token has access.

The final summary splits the checks into two readiness tracks:

- **Local development** — everything you need to run the recorder + web app against local Postgres.
- **Production deployment** — everything you need to deploy to Vercel, with a hosted Supabase + R2 bucket to back it.

Either track can be "ready" independently. If you don't care about local development and just want to run koom in production, the doctor still tells you exactly what's missing for prod, and vice versa.

A pre-commit hook (husky + lint-staged) runs ESLint, Prettier, `swift format`, ShellCheck, and gitleaks against staged changes before any commit lands. The same checks run in GitHub Actions on push and pull requests, plus a full-history gitleaks scan.

## Deeper reading

Longer-form write-ups of individual subsystems live in [`docs/`](docs/):

- [`docs/recording-output.md`](docs/recording-output.md) — codec, bitrate heuristic, and approximate file sizes produced by the macOS client.
- [`docs/crash-recovery.md`](docs/crash-recovery.md) — how the fragmented-MP4 session manager keeps a recording alive across force-quits and crashes.
- [`docs/post-upload-processing.md`](docs/post-upload-processing.md) — the on-device pipeline for auto-titles, word-level transcripts, and thumbnails.
- [`docs/monorepo-backend-plan.md`](docs/monorepo-backend-plan.md) — the original architectural decision record for the monorepo split.
- [`CLAUDE.md`](CLAUDE.md) — working rules, migration workflow, and the Supabase lockdown model used by every public table in the database.

The desktop app writes persistent logs to `~/Library/Logs/koom/koom.log` (with one rotated `koom.previous.log`). From the app itself, **Troubleshooting → Reveal Logs in Finder** jumps straight to that directory.
