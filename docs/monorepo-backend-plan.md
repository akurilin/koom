# Koom Monorepo, Web, and Backend Plan

Status: approved planning baseline for first implementation pass
Date: 2026-04-07
Working branch: `feat/monorepo-web-backend-foundation`

## Purpose

This document captures the agreed requirements, the architectural decisions already made, the decisions intentionally deferred, and the concrete implementation sequence for turning `koom` into a monorepo with:

- `client/` for the macOS desktop recorder
- `web/` for the Next.js application and backend API routes
- `scripts/` for operator tooling: the existing build/run wrappers plus an R2 setup script and a doctor script

The intent is that work can resume from this document alone without needing prior chat context.

## Product Summary

`koom` is a self-deployable Loom-style recorder for a single tenant. The user records a video locally in the macOS app, the finished MP4 uploads automatically, and the user gets a shareable watch URL that opens in a browser. Anyone with the link can view the recording. There are no user accounts, comments, transcription, search, or transcoding in v1.

The deployment target is opinionated and chosen to keep the steady-state monthly cost low for a single user:

- Web app hosted on **Vercel Hobby** (free)
- Metadata in **Supabase Postgres**, used only as a vanilla Postgres provider on the free tier (no Supabase Auth, no Supabase Storage)
- Video storage and CDN on **Cloudflare R2** (free tier headroom, pay-as-you-grow, zero egress fees)
- Auth is a single deployment-wide admin secret, no user accounts, no database rows for users

Target steady-state monthly cost at personal-scale usage: **~$0–5/month**. The only variable is R2 storage once the user accumulates more than 10 GB of recordings, and R2 has no egress charges at any scale.

No Loom-style features beyond the basics exist in v1: no comments, no transcription, no search, no team roles, no deletion workflows.

## Confirmed Decisions

These decisions were explicitly made and should be treated as settled for the first pass.

### Deployment and hosting

- Single-tenant, self-deployable.
- One deployment serves one person (or a very small team) under one operator-controlled setup.
- Web tier on **Vercel Hobby**.
- Metadata in **Supabase Postgres free tier** (treated as a pure Postgres provider — Supabase's own auth and storage products are intentionally not used).
- Video storage in **Cloudflare R2** with Cloudflare's built-in CDN fronting the bucket.
- No AWS resources.
- No Docker, no LocalStack, no MinIO in local development.

### Web and backend shape

- `web/` will contain a single Next.js application.
- The Next.js app will serve both frontend pages and backend API routes.
- The public watch page and internal admin pages live in the same app.

### Feature scope for v1

- No user accounts
- No comments
- No transcription
- No transcoding
- No indexing/search beyond a simple recordings list
- Minimal but visually appealing watch page
- Timestamp deep-linking should be supported

v1 _does_ include a database. The earlier sidecar-JSON-metadata idea has been discarded in favor of a single Postgres table. See [Database Schema](#database-schema).

### Access model

- Public watch pages are accessible to anyone with the link.
- Public links remain valid until the underlying recording is deleted from R2 (and its row removed from the database).
- `my recordings` and admin-oriented API endpoints are protected by a single deployment-wide admin secret.

### Recording and upload behavior

- The desktop client uploads automatically once recording completes.
- The client keeps the local file permanently for now.
- The client must never delete the local recording as part of the first pass.
- Upload failure must not destroy the local source file.
- After successful upload, the client copies the share URL to the clipboard and opens the watch page in the user's default browser.

### Storage and metadata

- One R2 bucket per deployment.
- Object layout: `recordings/{recordingId}/video.mp4`.
- **Metadata lives in Postgres**, not in sidecar JSON files.
- A single `recordings` table holds everything the app needs.

### Provisioning and operator tooling

- **Supabase**: DIY. The user creates a project in the Supabase dashboard and pastes the connection string into `web/.env.local`. No script touches Supabase.
- **Cloudflare R2**: hybrid. The user manually creates one Cloudflare API token (the only Cloudflare dashboard step), pastes it into `web/.env.local`, and runs `npm run r2:setup`. The script creates the bucket, generates S3 credentials, applies CORS, enables public access, and writes the resulting values back into `web/.env.local`. State is tracked in `scripts/.r2-state.json` so re-runs are safe and pre-existing resources are never modified.
- **Vercel**: DIY. The user connects the GitHub repo in the Vercel dashboard and copies the relevant env values into Vercel's env UI by hand.
- **No full bootstrap script in v1.** Fully automating Supabase project creation and Vercel project creation is deferred — neither saves enough manual effort to justify the maintenance cost yet.
- **Doctor script**: `npm run doctor` is a read-only verification sweep across the configured stack. Always safe to re-run.

### Technology preferences

- TypeScript throughout `web/` and `scripts/`.
- `pg` (node-postgres) for Postgres access. No ORM — raw parameterized SQL queries. koom's schema is small enough that an ORM's benefits don't outweigh the extra concept count, and raw SQL stays closer to what's actually running.
- Schema and migrations managed by the Supabase CLI. Migration files live in `supabase/migrations/` as hand-written SQL and are committed to the repo.
- Local development targets a Dockerized Supabase stack (`npm run db:start`). The hosted Supabase project is only used once production is ready.
- `@aws-sdk/client-s3` against R2's S3-compatible endpoint for bucket interactions and presigned URLs.
- Next.js App Router.
- `npm` workspaces at the repository root.
- `tsx` as the runner for the operator scripts (no build step).

## Current Codebase Facts

These observations come from the code already in the repository and affect the design.

### Current recorder behavior

- The macOS app already records screen video and optionally microphone audio.
- The app currently writes the finished MP4 to `~/Movies/koom/koom_YYYY-MM-DD_HH-mm-ss.mp4`.
- The app does not currently write to `/tmp`.
- Recording files are finalized on disk before any future upload step begins.

### Output characteristics

- Output container is MP4.
- Local recording codec is H.264.
- Recording writes directly to the final local output file.
- Default capture cadence is 15 fps, with a 30 fps option in Settings.
- Uploads can run a best-effort ffmpeg optimization pass that keeps the local file intact and uploads a smaller MP4 only when that re-encode is meaningfully smaller.
- Resolution follows the native display capture size.
- The current bitrate heuristic can produce fairly large files, especially for 4K displays. Rough guidance in the README is ~249 MB per minute for 4K, so a 30-minute recording can approach 7–8 GB.

### Build shape today

- The repo is currently a single Swift package at the repository root.
- Build and run scripts live in `scripts/` at the repository root.
- The app is built from `Package.swift` and `Sources/koom`.

## Architecture Overview

### 1. `client/`

The macOS app remains the screen recorder and becomes responsible for:

- capturing the recording locally
- keeping a durable local copy
- collecting basic recording metadata (size, duration when derivable)
- calling the web backend to initialize an upload session
- uploading the finalized file directly to R2 via a presigned URL
- notifying the backend that the upload is complete
- copying the share URL and opening it after success

The client never holds Cloudflare credentials. It only holds the web backend URL and the admin secret. All R2 interactions are mediated by short-lived presigned URLs minted by the backend.

### 2. `web/`

The Next.js app is both:

- the public watch application
- the admin control plane for upload orchestration and listing

It is responsible for:

- public watch routes
- admin pages such as `my recordings`
- admin session handling with a single shared secret (cookie for browsers, header for the desktop client — see [Admin Authentication Model](#admin-authentication-model))
- minting presigned R2 upload URLs
- verifying uploads completed (HEAD against R2)
- reading and writing the `recordings` table in Postgres
- constructing share URLs and public video URLs

The web app holds the R2 and Postgres credentials as Vercel environment variables. It never proxies video bytes.

### 3. Operator scripts

`scripts/` at the repo root holds operator tooling:

- existing `build-app.sh` and `run.sh` shell wrappers for the macOS client
- `r2-setup.ts` — provisions and reconciles the Cloudflare R2 bucket
- `doctor.ts` — read-only verification of the configured stack
- `.r2-state.json` — gitignored state file for the R2 setup script

See [Configuration, R2 Setup, and Doctor Script](#configuration-r2-setup-and-doctor-script).

## Repository Layout

```text
client/
  App/
  Sources/
  Package.swift
  scripts/
  assets/

web/
  app/
  components/
  lib/
    db/
      client.ts             # thin pg Pool wrapper reading DATABASE_URL
      queries.ts            # parameterized SQL query helpers
    r2/
      client.ts
    auth/
  public/
  package.json
  tsconfig.json
  next.config.ts
  .env.example              # committed template
  .env.local                # gitignored, real values

supabase/
  config.toml               # local stack configuration
  migrations/               # hand-written SQL migrations
    YYYYMMDDHHMMSS_create_recordings.sql
  seed.sql                  # optional — seed data for `db reset`
  .gitignore                # ignores .branches/, .temp/, etc.

docs/
  monorepo-backend-plan.md

scripts/
  build-app.sh              # existing
  run.sh                    # existing
  r2-setup.ts               # R2 provisioning
  doctor.ts                 # stack verification
  .r2-state.json            # gitignored, written by r2-setup.ts

README.md
package.json                # root workspaces manifest + tsx + script entries
```

### Notes on the root

- Root `package.json` declares `web` as the only `npm` workspace, plus `tsx` as a dev dependency, plus script entries for `r2:setup` and `doctor`.
- Root `scripts/build-app.sh` and `scripts/run.sh` remain as convenience wrappers that delegate into `client/scripts/*`.
- Root `README.md` explains the monorepo and points at the setup flow.

## URL Strategy

The canonical public share URL is:

```text
/r/[recordingId]
```

Timestamp deep-linking is supported via query parameter:

```text
/r/[recordingId]?t=123
```

### Why a stable `recordingId` instead of raw R2 details

- decouples public URLs from bucket layout
- lets the underlying storage evolve without breaking old links
- makes future auth, revocation, or indirection easier
- is the same pattern you'd want if you switched object stores later

This is a low-cost decision now and expensive to reverse later.

## Database Schema

One table. The schema lives in `supabase/migrations/*.sql` and is managed by the Supabase CLI. The web app reads and writes via raw parameterized queries through `pg` (node-postgres); there is no ORM layer.

```sql
CREATE TABLE recordings (
  id              TEXT PRIMARY KEY,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  status          TEXT NOT NULL CHECK (status IN ('pending', 'complete')),
  title           TEXT,
  original_filename TEXT NOT NULL,
  duration_seconds REAL,                    -- nullable; client may not always derive this
  size_bytes      BIGINT NOT NULL,
  content_type    TEXT NOT NULL DEFAULT 'video/mp4',
  bucket          TEXT NOT NULL,
  object_key      TEXT NOT NULL
);

CREATE INDEX recordings_status_created_at
  ON recordings (status, created_at DESC);
```

### Notes

- `id` is a UUID generated by the backend at `initUpload` time. The client never generates it.
- `status` is `'pending'` from `initUpload` until `completeUpload` verifies the object exists in R2, at which point it flips to `'complete'`.
- Listing queries filter `WHERE status = 'complete'` so mid-upload recordings never leak into the UI.
- `duration_seconds` is nullable because AVFoundation may not always yield a usable duration; the UI should degrade gracefully.
- Orphaned `pending` rows (init without complete) are acceptable in v1 and can be GC'd later with a simple `DELETE WHERE status='pending' AND created_at < now() - interval '1 day'`.

## Storage Layout (Cloudflare R2)

- One R2 bucket per deployment, created by `npm run r2:setup`.
- Bucket is **public-read** via R2's managed `.r2.dev` subdomain. Custom domain binding is deferred. Cloudflare's CDN is automatically in front either way.
- Object key convention: `recordings/{recordingId}/video.mp4`.
- Bucket CORS policy allows PUT and HEAD from any origin (the desktop client has no fixed origin).
- No sidecar JSON objects. All metadata lives in Postgres.

### Note on `.r2.dev` URLs

Cloudflare's managed `.r2.dev` URLs are intended for development and personal use. Cloudflare officially recommends binding a custom domain for production traffic, since `.r2.dev` URLs have rate limits intended to discourage production use. At single-user koom scale this is unlikely to matter, but it's worth knowing about. Custom domain binding is in [Deferred Decisions](#deferred-decisions).

### Pre-commitment verification

Before committing to R2, confirm that **HTTP Range requests work end-to-end through R2's public URL**. Browsers require 206 responses with `Content-Range` headers for `<video>` scrubbing and `?t=` deep-linking. This is standard behavior for R2 and its CDN, but it's a load-bearing assumption and worth a 5-minute test before building the whole upload flow:

1. Manually upload a small MP4 to an R2 bucket via the dashboard.
2. Open the public URL in a browser `<video>` element.
3. Confirm the network panel shows 206 responses with `Content-Range` when seeking.

The doctor script performs this same check programmatically once the bucket is set up, but verifying once by hand before writing any code is cheap insurance.

## Public and Admin Surfaces

### Public surfaces

- `GET /r/[recordingId]` — watch page
- `GET /api/public/recordings/[recordingId]` — recording metadata JSON

Note: there is **no** `/api/public/video/[id]` proxy route. The watch page renders a `<video>` element pointing directly at the R2 public URL. Video bytes never flow through Vercel.

### Admin surfaces

- `GET /app/login` — admin login page
- `POST /api/admin/session` — create session
- `POST /api/admin/session/logout` — destroy session
- `GET /app/recordings` — my recordings page
- `GET /api/admin/recordings` — recordings list
- `POST /api/admin/uploads/init` — start an upload, return a presigned URL
- `POST /api/admin/uploads/complete` — finalize an upload

Exact route names may change slightly during implementation, but the separation of public and admin concerns remains.

## Admin Authentication Model

V1 uses a single deployment-wide admin secret (`KOOM_ADMIN_SECRET`) rather than a user system.

### Two accepted credentials, one secret

Admin endpoints accept either of two credentials, both validated against the same `KOOM_ADMIN_SECRET`:

1. **Signed session cookie** — used by the browser. Set after `POST /api/admin/session` succeeds. Stores no user identity; it's just "this browser proved knowledge of the secret."
2. **`Authorization: Bearer <secret>` header** — used by the desktop client. The client stores the secret in the macOS Keychain and sends it on every admin request. No session flow, no cookie jar needed in Swift.

### Browser flow

1. User visits `/app/login`.
2. User enters the shared admin secret.
3. Next.js verifies it against `KOOM_ADMIN_SECRET`.
4. On success, the app sets a signed session cookie (e.g. via `iron-session` or similar).
5. Admin pages and admin API routes check for that cookie OR the bearer header.

### Desktop client flow

1. User pastes the admin secret once into the client settings.
2. Client stores it in the macOS Keychain.
3. Every admin API request includes `Authorization: Bearer <secret>`.
4. No cookie handling in the Swift client.

This gives us one secret, two transport mechanisms, and no user table.

## Upload Contract

The upload flow uses presigned R2 URLs. The desktop client never sees Cloudflare credentials; the backend never sees video bytes.

### High-level flow

1. Client finishes recording locally.
2. Client stats the finalized file for `sizeBytes` and attempts to derive `durationSeconds` via AVFoundation (nullable).
3. Client calls `POST /api/admin/uploads/init`.
4. Backend:
   - Generates a UUID `recordingId`.
   - Inserts a row into `recordings` with `status='pending'`.
   - Generates a presigned PUT URL for `recordings/{recordingId}/video.mp4` in the R2 bucket, valid for ~15 minutes.
   - Returns `{ recordingId, upload, shareUrl }`.
5. Client PUTs the MP4 bytes directly to the presigned URL. These bytes go to R2, not to Vercel.
6. Client calls `POST /api/admin/uploads/complete` with `{ recordingId }`.
7. Backend:
   - Issues a HEAD request against the R2 object to confirm it exists and matches the expected size.
   - Updates the `recordings` row to `status='complete'`.
   - Returns `{ recordingId, shareUrl }`.
8. Client copies `shareUrl` to clipboard and opens it in the default browser.

### Single PUT vs multipart

A single presigned PUT tops out at 5 GB per object (S3 protocol limit; R2 inherits it). At koom's ~250 MB/min for 4K that's ~20 minutes of recording. For v1, assume single PUT and document the ~20-minute practical cap. When the first "file too large" case appears, add multipart upload: the backend mints multiple presigned URLs (one per part, typically 5–100 MB), the client uploads them in parallel, and the backend calls `CompleteMultipartUpload`.

The `upload` field in the init response is shaped to allow future multipart strategies without breaking the client:

```json
"upload": {
  "strategy": "single-put",
  "method": "PUT",
  "url": "https://<r2-endpoint>/...?X-Amz-Signature=...",
  "headers": { "Content-Type": "video/mp4" }
}
```

The client switches on `strategy`. In v1 only `single-put` exists.

### Request and response shapes

#### `POST /api/admin/uploads/init`

Request:

```json
{
  "originalFilename": "koom_2026-04-06_08-34-56.mp4",
  "contentType": "video/mp4",
  "sizeBytes": 123456789,
  "durationSeconds": 123.45,
  "title": null
}
```

`durationSeconds` and `title` are optional / nullable.

Response:

```json
{
  "recordingId": "4f3a...",
  "upload": {
    "strategy": "single-put",
    "method": "PUT",
    "url": "https://<account>.r2.cloudflarestorage.com/<bucket>/recordings/4f3a.../video.mp4?X-Amz-...",
    "headers": { "Content-Type": "video/mp4" }
  },
  "shareUrl": "https://koom.example.com/r/4f3a..."
}
```

#### `POST /api/admin/uploads/complete`

Request:

```json
{ "recordingId": "4f3a..." }
```

Response:

```json
{
  "recordingId": "4f3a...",
  "shareUrl": "https://koom.example.com/r/4f3a..."
}
```

#### `GET /api/public/recordings/[recordingId]`

Response:

```json
{
  "recordingId": "4f3a...",
  "createdAt": "2026-04-06T12:34:56.000Z",
  "title": null,
  "videoUrl": "https://<bucket>.r2.dev/recordings/4f3a.../video.mp4",
  "durationSeconds": 123.45,
  "sizeBytes": 123456789
}
```

`videoUrl` points directly at R2. The watch page uses this as the `src` of its `<video>` element.

#### `GET /api/admin/recordings`

Response:

```json
{
  "recordings": [
    {
      "recordingId": "4f3a...",
      "createdAt": "2026-04-06T12:34:56.000Z",
      "title": null,
      "sizeBytes": 123456789,
      "durationSeconds": 123.45,
      "shareUrl": "https://koom.example.com/r/4f3a..."
    }
  ]
}
```

Backed by a `SELECT * FROM recordings WHERE status='complete' ORDER BY created_at DESC`.

## Watch Page Requirements

The public watch page should be intentionally minimal but not crude.

Expected behavior:

- clean layout around a standard HTML5 `<video>` element
- `src` points at the R2 public URL returned from `/api/public/recordings/[id]`
- support playback speed changes through the browser's controls
- support timestamp deep-linking using `?t=` (seek on load)
- render basic metadata like created date, duration, size
- handle missing recordings gracefully (404 page)

No streaming format beyond raw MP4 is needed in v1. R2 + Cloudflare CDN handle Range requests for scrubbing.

## My Recordings Page

The first internal management surface is a simple `my recordings` page in the Next.js app.

Expected behavior:

- only visible to authenticated admin users (cookie or bearer)
- list recordings newest-first (query: `WHERE status='complete' ORDER BY created_at DESC`)
- show created date, size, duration, and share link
- click-through to the watch page
- optionally show the underlying R2 object key for debugging

No search, pagination, or editing in the first pass.

## Client Integration Plan

Desktop client changes are additive and isolated.

### New client responsibilities

- stat the finalized local file to get `sizeBytes`
- attempt to derive `durationSeconds` from the finalized asset via AVFoundation (optional)
- call `POST /api/admin/uploads/init` with the metadata
- PUT the video bytes to the returned presigned URL, streaming from disk (never load the whole file into memory)
- call `POST /api/admin/uploads/complete`
- copy the returned `shareUrl` to the clipboard
- open the `shareUrl` in the default browser
- preserve the local file on all paths, including every failure path

### Client configuration

Two values the client needs:

- **Backend base URL** — e.g. `https://koom.example.com` in production, `http://localhost:3000` in dev. Stored in `UserDefaults`.
- **Admin secret** — stored in the **macOS Keychain**, not `UserDefaults`.

Settings UI can be rough in v1 (a window with two text fields) as long as the integration works.

### Error handling requirements

- Upload failures must not clear the successful local recording.
- The client should surface a clear failure state and preserve enough information to retry.
- Success is only declared after `completeUpload` returns 200.
- Presigned URL expiry is handled by requesting a fresh init if the PUT fails with 403/expired.

## Monorepo Migration Plan

The first structural step is moving the current Swift app into `client/` without changing its behavior.

### Migration target

Move:

- `Package.swift` → `client/Package.swift`
- `Sources/` → `client/Sources/`
- `App/` → `client/App/`
- `assets/` → `client/assets/`
- existing app-specific scripts → `client/scripts/`

Keep or recreate root wrappers:

- `scripts/build-app.sh`
- `scripts/run.sh`

These root wrappers delegate to `client/scripts/*` so existing top-level commands remain discoverable.

## Tooling

### Node workspace

Root `package.json` with `npm` workspaces covering:

- `web`

`scripts/` is intentionally not a workspace — it's a flat directory of TypeScript files that the root `package.json` runs via `tsx`.

### Web stack

- Next.js (App Router)
- TypeScript
- `pg` (node-postgres) against Postgres, with raw parameterized queries. No ORM.
- Supabase CLI for local Postgres stack (`npm run db:start`) and migration management
- `@aws-sdk/client-s3` + `@aws-sdk/s3-request-presigner` against R2
- `iron-session` (or equivalent) for the signed admin cookie
- Minimal CSS approach — Tailwind is fine if it speeds things up, plain CSS modules are also fine

### Operator scripts stack

- TypeScript executed by `tsx` (no build step)
- `dotenv` to read `web/.env.local` from a sibling path
- `@aws-sdk/client-s3` for R2 verification in the doctor script
- `pg` for Postgres connectivity checks
- Direct `fetch` calls against the Cloudflare REST API for R2 provisioning

### Styling

The watch page and admin pages should look intentional, not template-generic. Not the highest-risk area, but the product should not look careless.

## Configuration, R2 Setup, and Doctor Script

V1 uses a hybrid provisioning approach: Supabase and Vercel are DIY, Cloudflare R2 is automated by `scripts/r2-setup.ts`, and `scripts/doctor.ts` verifies the whole stack end-to-end.

### Configuration files

All app configuration lives in `web/`:

- **`web/.env.example`** — committed template documenting every variable, with a per-service section explaining where to find the values. The Cloudflare section gets the most documentation love because it's the only step a Cloudflare newcomer has to navigate the dashboard for.
- **`web/.env.local`** — gitignored, contains the actual values. Auto-loaded by Next.js on `next dev` and `next build`.

Putting these inside `web/` matches Next.js conventions and means `next dev` "just works" without custom env loading. The operator scripts in `scripts/` read `web/.env.local` by relative path via `dotenv`.

### Required env vars

The `.env.example` file documents these in detail with inline instructions. The variables themselves:

```bash
# ─── Supabase Postgres (DIY) ────────────────────────────────────────
# Create a project at https://supabase.com/dashboard, then go to:
#   Project Settings → Database → Connection string → "URI" mode
# Use the connection-pooler version (port 6543, ?pgbouncer=true)
# for compatibility with serverless/edge runtimes.
DATABASE_URL=

# ─── Cloudflare R2 (token DIY, rest automated) ──────────────────────
# Step 1: Create an API token at:
#   https://dash.cloudflare.com/profile/api-tokens
#   → "Create Token" → "Create Custom Token"
#   → Permissions: "Workers R2 Storage" → "Edit"
#   → Account Resources: include your account
#   → (no zone or user resources needed)
# Step 2: Find your Account ID on the right sidebar of any page
#   in the Cloudflare dashboard once you're logged in.
# Step 3: Paste both below.
# Step 4: Run `npm run r2:setup`. The script fills in the
#   remaining R2_* values automatically.
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=

# Filled in by `npm run r2:setup`. Do not edit by hand.
R2_BUCKET=
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
R2_ACCOUNT_ID=
R2_PUBLIC_BASE_URL=

# ─── Vercel deployment (DIY) ────────────────────────────────────────
# Local dev value below. The production value lives in the Vercel
# project's env settings, not in this file.
KOOM_PUBLIC_BASE_URL=http://localhost:3000

# Generate any random string. Used for admin cookie + Authorization
# bearer auth. Same secret in dev and prod is fine for v1.
KOOM_ADMIN_SECRET=

# Optional: paste a Vercel personal access token + project ID
# to enable doctor script Vercel checks. Not required at runtime.
VERCEL_TOKEN=
VERCEL_PROJECT_ID=
```

For Vercel deployment, copy the production-relevant subset of these (`DATABASE_URL`, `R2_*`, `KOOM_*`) into the Vercel project's environment variables UI by hand. `KOOM_PUBLIC_BASE_URL` is the only one whose value should differ from `.env.local` — set it to the deployed Vercel URL in production.

### `scripts/r2-setup.ts`

A TypeScript script runnable via `npm run r2:setup`. It provisions or reconciles the Cloudflare R2 setup using credentials from `web/.env.local`. State persists in `scripts/.r2-state.json`.

#### Behavior on first run

1. Reads `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from `web/.env.local`. Errors clearly if either is missing.
2. Validates the token against Cloudflare's API.
3. Lists existing R2 buckets in the account. If a bucket named `koom-recordings` already exists:
   - Prompts: "Bucket 'koom-recordings' already exists in this account. Reuse it? [y/N]"
   - On `y`: records `createdByKoom: false` in state and proceeds with connecting to it.
   - On `n`: exits with a message asking to either delete the existing bucket or pick a different name.
4. If no existing bucket: creates `koom-recordings`. Records `createdByKoom: true` in state.
5. Generates an R2 S3-compatible API token scoped to the bucket. Records the token ID in state with a description like `koom-app-<timestamp>` so the user can identify it later in the dashboard.
6. Applies a CORS policy allowing `PUT` and `HEAD` from `*`.
7. Enables the managed `.r2.dev` public URL for the bucket. Captures the resulting public base URL.
8. Writes `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, `R2_PUBLIC_BASE_URL` back into `web/.env.local`, replacing any existing values for those keys (preserving everything else).
9. Writes `scripts/.r2-state.json`.
10. Prints a summary and recommends running `npm run doctor`.

#### Behavior on re-run

1. Reads `scripts/.r2-state.json`.
2. Verifies each tracked resource still exists and matches expectations:
   - Bucket present?
   - S3 token still valid (best-effort check)?
   - CORS policy still matches the expected hash?
   - Public access still enabled?
3. Reports any drift, prompts before re-applying.
4. **Never touches resources where `createdByKoom: false`** — only verifies they're still reachable.

#### A note on the "Workers R2 Storage: Edit" permission

The exact permission scope needed for _all_ steps of the script is mostly covered by "Workers R2 Storage: Edit", but creating R2 S3 credentials (step 5 above) may require an additional account-level scope that hasn't been verified. If step 5 returns a 403, the script's error output will include the missing scope from Cloudflare's response, and the user updates the token in the dashboard and re-runs. Worst case is one iteration. The `.env.example` documentation should be updated with the final correct scope once verified during Phase 6.

### `scripts/.r2-state.json`

Gitignored. Tracks what `r2-setup.ts` created.

```json
{
  "version": 1,
  "cloudflare": {
    "accountId": "abc123...",
    "bucket": {
      "name": "koom-recordings",
      "createdByKoom": true,
      "createdAt": "2026-04-07T12:00:00.000Z"
    },
    "s3Token": {
      "id": "tok-...",
      "createdByKoom": true,
      "createdAt": "2026-04-07T12:00:00.000Z"
    },
    "cors": {
      "appliedByKoom": true,
      "rulesHash": "sha256:..."
    },
    "publicAccess": {
      "enabledByKoom": true,
      "publicBaseUrl": "https://pub-xyz.r2.dev"
    }
  }
}
```

The `createdByKoom` flag is the safety model. Three guarantees follow from it:

1. **Pre-existing resources are never modified.** If the user reuses an existing bucket, it's recorded `createdByKoom: false` and the script will only read from it, never reconfigure it.
2. **Re-runs are diff-aware.** Drift detection runs before any mutation; the script prompts before changing anything.
3. **A future teardown command would only delete things we created.** Anything `createdByKoom: false` stays permanently safe from automated deletion.

Deleting the state file resets the script to "fresh provision" mode. Because step 3 of first-run behavior detects existing buckets and prompts, this is still safe — the worst case is one extra prompt.

### `scripts/doctor.ts`

Runnable via `npm run doctor`. Read-only verification (plus one self-cleaning test upload). Independent of `r2-setup.ts` — it verifies whatever current state exists, regardless of how it got there. Useful any time something seems off, not just at initial setup.

#### Checks

- All required env vars present and non-empty
- Postgres connects with SSL, basic query succeeds
- `recordings` table exists and is queryable (warns clearly if migrations haven't run yet)
- R2 credentials valid, bucket exists, account ID matches
- Test PUT of a small throwaway object succeeds
- Public URL serves the test object
- **R2 returns 206 with `Content-Range` on Range requests** — load-bearing video-playback check
- CORS policy allows the methods we need
- Vercel token valid and project exists (if `VERCEL_TOKEN` and `VERCEL_PROJECT_ID` are provided; skipped otherwise)
- `KOOM_ADMIN_SECRET` is set and non-empty
- Test object cleaned up before exit

#### Output

Styled like `brew doctor` / `flutter doctor`: all checks run, failures collected, summary at the bottom with fix guidance per failure. Checks that depend on a deployed Vercel URL (e.g., reachability of the deployed instance) skip gracefully when run pre-deploy. Exit code is non-zero if any check failed, so it's CI-friendly later.

### Cost and reversibility guarantees

Both scripts are designed to be safe to run repeatedly:

- `r2-setup.ts` only creates resources the user asked for, tracked by state, fully reversible by hand via the Cloudflare dashboard. An empty R2 bucket is free.
- `doctor.ts` only writes one tiny throwaway object (~1 KB) and deletes it before exit. No persistent mutation of any system.
- Neither script can cost the user money in any meaningful sense at this scale.

## Phased Execution Plan

Execute in this order.

### Phase 1. Monorepo restructure

- Create the root `npm` workspace.
- Move the Swift app into `client/`.
- Preserve root build and run ergonomics via wrapper scripts.
- Update the root `README.md`.
- Confirm the macOS app still builds and runs unchanged.

### Phase 2. Web scaffold + database

- Create `web/` Next.js app with the App Router and TypeScript.
- Install `pg` and `@types/pg` in the `web/` workspace.
- Initialize the local Supabase stack (`supabase init` + `npm run db:start`) so development runs against a Dockerized Postgres, not the hosted project.
- Add the first migration in `supabase/migrations/` creating the `recordings` table.
- Apply migrations to the local stack via `npm run db:reset`.
- Write a thin `web/lib/db/client.ts` wrapping a `pg.Pool` around `DATABASE_URL`.
- Create `web/.env.example` (committed) and `web/.env.local` (gitignored). Local `DATABASE_URL` defaults to `postgresql://postgres:postgres@127.0.0.1:54322/postgres`.
- Add admin session handling: login page, cookie, bearer header, route guard.

### Phase 3. R2 integration

- Add `@aws-sdk/client-s3` configured against the R2 endpoint.
- Use a hand-created dev R2 bucket initially (the `r2-setup.ts` script comes in Phase 6).
- Implement `POST /api/admin/uploads/init` (insert pending row, mint presigned PUT URL).
- Implement `POST /api/admin/uploads/complete` (HEAD the object, flip status).
- Implement `GET /api/admin/recordings` and `GET /api/public/recordings/[id]`.
- Manually verify Range requests work end-to-end against the dev bucket.

### Phase 4. Public and admin UI

- Build the public watch page pointing `<video>` at the R2 URL.
- Build the admin login page.
- Build the `my recordings` page.

### Phase 5. Client upload integration

- Add backend URL and admin secret configuration to the client (UserDefaults + Keychain).
- Add upload orchestration after recording stop: init → streaming PUT → complete.
- Add clipboard copy and browser open on success.
- Ensure local file retention is unchanged on all paths.

### Phase 6. R2 setup and doctor scripts

- Add `tsx` as a root dev dependency.
- Implement `scripts/r2-setup.ts`: token validation, bucket detection/creation, S3 credential generation, CORS, public access, state file, env file rewrite.
- Implement `scripts/doctor.ts`: env presence, Postgres connectivity, R2 reachability, test PUT/GET/Range, optional Vercel check.
- Verify both scripts against a fresh Cloudflare account end-to-end.
- Update `web/.env.example` with the verified Cloudflare permission scope.
- Document the manual Supabase and Vercel steps in the root `README.md`.

## Acceptance Criteria for the First Implementation Pass

The first pass is successful if all of the following are true:

- The repo is reorganized into `client/`, `web/`, and root-level `scripts/`.
- The desktop app still builds and runs from the repo.
- The web app runs locally against a real Supabase free-tier Postgres and a real R2 bucket.
- The web app can accept a recording upload via presigned URL and record metadata in Postgres.
- The web app can render a public watch page for an uploaded recording, with working scrubbing and `?t=` deep-linking.
- The web app can render an authenticated `my recordings` page.
- The desktop client can upload a finished recording using the init → PUT → complete flow.
- The client keeps the local file after upload.
- The client copies the share URL and opens it after successful upload.
- `npm run r2:setup` provisions a fresh R2 bucket end-to-end against an account that has nothing pre-existing.
- `npm run r2:setup` correctly detects and refuses to mutate a pre-existing bucket without explicit consent.
- `npm run doctor` passes all checks against the configured deployment.

## Known Risks and Constraints

### Large file handling

Recordings can be multi-GB. All upload code (client and server) must stream, never buffer. The backend never proxies video bytes; it only issues presigned URLs and reads small JSON bodies.

### 5 GB single-PUT ceiling

The single presigned PUT path tops out at 5 GB (~20 minutes at 4K). Multipart upload is deferred until the first real file hits the ceiling.

### R2 Range request assumption

R2 should support HTTP Range requests on public URLs. This is a load-bearing assumption for video playback and deep-linking. **Verify with a manual test before Phase 3** — and the doctor script in Phase 6 will assert it programmatically.

### Listing without indexing

A single-table `SELECT ... ORDER BY created_at DESC` with a covering index is fine at single-user scale. No search, no pagination, no full-text in v1.

### R2 billing friction

Cloudflare requires a payment method on file to enable R2, even at free-tier usage levels. The `web/.env.example` Cloudflare section and the root `README.md` setup instructions must surface this up front so users aren't surprised mid-setup.

### `.r2.dev` rate limits

Cloudflare's managed `.r2.dev` URLs have rate limits intended to discourage production use. At single-user scale this is unlikely to matter; if it ever does, custom domain binding is the documented escape hatch.

### Vercel Hobby limits

Vercel Hobby has per-request body size and execution-time limits. These do not affect koom because video bytes bypass Vercel entirely — the only bodies Vercel sees are small JSON payloads. Worth noting so future contributors don't accidentally reintroduce a video-proxying route.

### Supabase free tier pause behavior

Supabase free-tier projects are paused after a week of inactivity and must be unpaused manually from the dashboard. For a personal tool used weekly, this is usually fine. If it becomes annoying, upgrading one tier or switching to Neon (which scales to zero more gracefully) is a one-env-var change.

### Cloudflare API token permission scope uncertainty

The exact Cloudflare API token scopes needed for _all_ steps of `r2-setup.ts` are not 100% verified — specifically, creating R2 S3 credentials may require an additional permission beyond "Workers R2 Storage: Edit". If hit, the script surfaces the missing scope from the API error and the user updates the token. The Phase 6 verification step pins down the final correct scope and updates the docs.

## Deferred Decisions

- Multipart upload for files larger than 5 GB
- Custom domains and DNS automation (including custom domain binding for R2)
- Deletion workflows
- Link revocation without deleting the underlying object
- Comments, collaboration, annotations
- Transcription
- Transcoding and alternate renditions
- User accounts and multi-tenant support
- Multi-environment (dev/staging/prod) deploys
- Proper settings UI in the desktop client
- Fully automated bootstrap for Supabase project creation and Vercel project creation (currently DIY because manual creation takes 2 minutes per service and the dashboard UX is the value prop for both)
- A teardown command for `r2-setup.ts` (state file already supports it; just not built yet)

## Resume Checklist

If work resumes later, the next practical actions are:

1. Verify the branch is `feat/monorepo-web-backend-foundation`.
2. Move the Swift app into `client/` and keep root wrappers working.
3. Create the root Node workspace and scaffold `web/`.
4. Run `npm run db:start` to boot the local Supabase stack; create a dev R2 bucket via `npm run r2:setup`.
5. Add the first migration in `supabase/migrations/` creating the `recordings` table; apply via `npm run db:reset`.
6. Implement admin auth (cookie + bearer) against `KOOM_ADMIN_SECRET`.
7. Implement `uploads/init`, `uploads/complete`, `recordings/list`, `recordings/get` using parameterized `pg` queries.
8. Build the public watch page and the admin `my recordings` page.
9. Verify Range requests work end-to-end against R2 before wiring the client.
10. Integrate the desktop client upload path.
11. Harden and test `scripts/r2-setup.ts` and `scripts/doctor.ts` on a fresh machine; backfill `web/.env.example` with any new setup instructions.

## External Reference Notes

These references are expected to remain relevant during implementation:

- Cloudflare R2 S3 API compatibility and presigned URL docs
- Cloudflare R2 public buckets, `.r2.dev` URLs, and custom domain binding
- Cloudflare REST API docs for R2 bucket creation, S3 token creation, CORS, and public access management
- Cloudflare API token permission groups (specifically "Workers R2 Storage")
- AWS SDK v3 (`@aws-sdk/client-s3`, `@aws-sdk/s3-request-presigner`) usage against S3-compatible endpoints
- Supabase CLI docs: local dev stack, migrations, `db reset` workflow
- Supabase Postgres connection string format and SSL requirements for the hosted tier
- `pg` (node-postgres) parameterized query API and connection pooling
- Vercel project environment variable management via dashboard
- Next.js App Router route handler docs and `.env.local` loading behavior
- `iron-session` or equivalent for signed cookies in Next.js
- `tsx` for running TypeScript scripts without a build step
