# koom

## Working Rules

- Do not commit unless the user explicitly asks for a commit.
- Prefer terminal-only workflows. Do not introduce an Xcode project unless the user explicitly asks for one.
- `npm run doctor` verifies the operator's environment (Postgres reachable, R2 bucket configured, env vars present, Range requests working, Ollama + auto-title model reachable). It is **not** a per-change check and should not be run after routine code edits — use `npm test` and `npm run lint` / `npm run format:check` for that. Run doctor only when validating a fresh setup, after env-var or infra changes, or when debugging end-to-end infrastructure issues.

## Build Hygiene

- Treat sensible compiler, linker, linter, and build warnings as actionable by default.
- If a warning looks like it may indicate a real source issue, address it during the task instead of ignoring it.
- Examples include concurrency/sendability warnings, API misuse, deprecated APIs with clear replacements, lifetime issues, and warnings that suggest future breakage.
- If a warning is benign or cannot be resolved cleanly in the current task, call that out explicitly in the handoff instead of silently leaving it behind.

## Database Migrations

- Follow the style and conventions of the official PostgreSQL manual for all migration SQL: uppercase keywords, lowercase `snake_case` identifiers, canonical type names (`TEXT`, `BIGINT`, `TIMESTAMPTZ`, `REAL`), and aligned column definitions. When in doubt about formatting a construct, check how the Postgres docs format the equivalent.
- Migration files live in `supabase/migrations/` and use the `YYYYMMDDHHMMSS_short_description.sql` naming scheme so the Supabase CLI applies them in order. Each file should start with a comment block describing the intent of the migration and any non-obvious decisions.

## Commands

- Build app bundle: `./scripts/build-app.sh`
- Run app in foreground: `./scripts/run.sh`
