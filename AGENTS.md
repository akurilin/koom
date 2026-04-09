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

- **All schema changes — local and remote — go through the Supabase CLI. Never run `CREATE TABLE`, `ALTER TABLE`, `DROP ...`, or any other DDL against a koom database via raw `psql`, Supabase Studio's SQL editor, or any other out-of-band path.** Raw-SQL changes skip `supabase_migrations.schema_migrations`, which puts the local and remote migration state out of sync and breaks the next `supabase db push`. The only exception is genuine break-glass recovery, and that should be called out explicitly in the handoff.
- The canonical workflow is: `npm run db:migration:new <slug>` to scaffold the timestamped file → edit the SQL → `npm run db:reset` to apply locally and confirm it works → `npm run db:verify` to run the public-schema lockdown invariants against the freshly-migrated local stack → commit the migration file → `npx -y supabase@2.87.2 db push -p '<password>'` to apply to the linked remote project. CI runs `db:verify` automatically after applying migrations, but running it locally is the fastest feedback loop.
- Read-only inspection with `psql` (e.g. `\d recordings`, `SELECT ...`) is fine and encouraged for debugging. The rule is specifically about **mutations**.
- Follow the style and conventions of the official PostgreSQL manual for all migration SQL: uppercase keywords, lowercase `snake_case` identifiers, canonical type names (`TEXT`, `BIGINT`, `TIMESTAMPTZ`, `REAL`), and aligned column definitions. When in doubt about formatting a construct, check how the Postgres docs format the equivalent.
- Migration files live in `supabase/migrations/` and use the `YYYYMMDDHHMMSS_short_description.sql` naming scheme so the Supabase CLI applies them in order. Each file should start with a comment block describing the intent of the migration and any non-obvious decisions.

## Database Access Model (Supabase lockdown)

- **koom deliberately does not use Supabase's auto-exposed APIs.** PostgREST, pg_graphql, Supabase Auth, Storage, and Realtime are all either dropped, neutralized, or left empty. The Next.js app connects to Postgres directly through the `pg` pool as the table-owning `postgres` role (which holds `BYPASSRLS`) and that is the only intended data path. If you ever have the urge to "just hit PostgREST from the browser for this one thing," stop and ask first — it breaks the security model.
- **Every new `public.*` table is automatically locked down at creation time** by the DDL event trigger installed in `supabase/migrations/20260409193257_lock_down_public_access.sql`. The trigger runs `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` on every new table in `public`, and the same migration flipped `ALTER DEFAULT PRIVILEGES` so new tables land without the `anon`/`authenticated` grants Supabase would otherwise auto-attach. Result: any new table is deny-by-default against the API role-switches without any per-migration discipline.
- **To deliberately opt a future table INTO PostgREST** (e.g. if you ever want a genuinely public read path), do it explicitly in the same migration that creates the table: after `CREATE TABLE public.foo (...)`, add `ALTER TABLE public.foo DISABLE ROW LEVEL SECURITY;` (or write a policy) and `GRANT SELECT ON TABLE public.foo TO anon, authenticated;`. The exposure must be a conscious, reviewable choice — that's the whole point of inverting the default.
- **Do not remove or rename `koom_lock_down_new_public_table()` or `koom_lock_down_new_public_tables`** without a replacement in the same migration. Losing the trigger silently re-opens the footgun. The `koom_` prefix distinguishes these from upstream Supabase-owned event triggers (`graphql_watch_*`, `pgrst_*`, `issue_*`); if you ever copy an updated version of Supabase's official `rls_auto_enable` pattern to modernize our implementation, remember to re-apply the `koom_` prefix before pushing.
- **`pg_graphql` is intentionally dropped** in that same migration. If a future requirement genuinely needs GraphQL, reinstall with `CREATE EXTENSION pg_graphql;` in a new migration and document why the exposure is desirable; don't quietly re-add it.
- **The lockdown posture is continuously verified** by `supabase/tests/database/public_schema_lockdown.sql`, a plain-SQL invariant test executed via `npm run db:verify`. It checks: every public table has RLS enabled, `anon`/`authenticated` hold zero grants on tables, sequences, or functions in public, no RLS policies exist in public (see tradeoff note below), the `koom_lock_down_new_public_tables` event trigger is installed and enabled, `pg_graphql` is not installed, and every view in public has `security_invoker=true`. CI runs it after every migration apply; run it locally after `npm run db:reset`. To add a new invariant, append a new `DO` block to that file following the existing pattern (`RAISE EXCEPTION` with the offending object name in the message).
- **The invariant test forbids ALL RLS policies in `public` — this is a deliberate tradeoff, not an oversight.** In koom's model, `public.*` tables are never reached through PostgREST or `anon`/`authenticated`, so RLS policies on them would be dead code that the app (connecting as `postgres` with `BYPASSRLS`) never consults. A policy appearing on a public table is therefore almost always either a copy-pasted Supabase tutorial snippet that assumed a frontend-to-PostgREST architecture, OR a live attempt to expose data to the API role-switches without taking the explicit opt-in path. Both should fail loudly. The cost is that the canonical Supabase "RLS policies gate per-row access via PostgREST" pattern isn't available without explicitly relaxing the check. If a future feature legitimately needs a policy, **do not delete or weaken check #5** in `public_schema_lockdown.sql` — instead update its `WHERE` clause to allowlist the specific `(schema, table, policy)` tuple by name. That preserves the "every policy in public is a grep-able, reviewable, named decision" property. The test file's check #5 comment block spells out the pattern in full.

## Commands

- Build app bundle: `./scripts/build-app.sh`
- Run app in foreground: `./scripts/run.sh`
