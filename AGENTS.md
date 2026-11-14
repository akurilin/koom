# koom

## Working Rules

- Do not commit unless the user explicitly asks for a commit.
- Do not push unless the user explicitly asks to push.
- Prefer terminal-only workflows. Do not introduce an Xcode project unless the user explicitly asks for one.
- `npm run doctor` verifies self-host/operator readiness without requiring the local Docker stack. `npm run doctor:dev` verifies local-development readiness without requiring access to the Render deployment, and `npm run doctor:all` runs both paths. These are **not** per-change checks and should not be run after routine code edits — use `npm test` and `npm run lint` / `npm run format:check` for that. Run a doctor only when validating a fresh setup, after env-var or infra changes, or when debugging end-to-end infrastructure issues.
- **When running the koom app agentically (no human at the keyboard), always launch with `KOOM_ADMIN_SECRETS_FILE=~/.config/koom/admin-secrets.json`.** Without it, the app reads the admin secret from the Keychain, and because each rebuild re-signs the binary, macOS shows a password prompt that silently blocks the run until a human answers it.

## Build Hygiene

- Treat sensible compiler, linker, linter, and build warnings as actionable by default.
- If a warning looks like it may indicate a real source issue, address it during the task instead of ignoring it.
- Examples include concurrency/sendability warnings, API misuse, deprecated APIs with clear replacements, lifetime issues, and warnings that suggest future breakage.
- If a warning is benign or cannot be resolved cleanly in the current task, call that out explicitly in the handoff instead of silently leaving it behind.

## Testing

- Only write tests with real leverage: nontrivial logic, parsing, persistence round-trips, state machines, API contracts.
- Do not write tests that restate constants — asserting a default value, an enum's raw value, a label string, and the like. A test that mirrors a one-line setting can't catch a bug; it just adds a second place to edit when the value changes. The same goes for any test that is effectively a layer of indirection over something shallow.

## Database Migrations

- **All schema changes — local and production — go through migration files in `db/migrations/`, applied by `scripts/db.ts`. Never run `CREATE TABLE`, `ALTER TABLE`, `DROP ...`, or any other DDL against a koom database via raw `psql`, the Render dashboard, or any other out-of-band path.** Out-of-band changes skip the `schema_migrations` bookkeeping table, so the next deploy's migration run no longer matches the real schema. The only exception is genuine break-glass recovery, and that should be called out explicitly in the handoff.
- Local development uses a project-local Postgres 17 container (`docker-compose.yml`) holding a dedicated `koom` database on `127.0.0.1:54322`. Production is the `koom-db` Render Postgres instance declared in `render.yaml`. Keep the Postgres major version in lockstep across `docker-compose.yml`, `render.yaml`, `.squawk.toml`, and the CI service container.
- The canonical workflow is: `npm run db:start` (once per boot) → `npm run db:migration:new <slug>` to scaffold the timestamped file → edit the SQL → `npm run db:reset` to rebuild the local database from scratch and confirm it applies → `npm run sql:lint` → commit the migration file. Render applies it automatically: the koom-web service's `preDeployCommand` runs `npm run db:migrate` before each release goes live, and a failing migration fails the deploy. CI runs the same `db:migrate` against a fresh Postgres before the integration tests.
- `db:reset` refuses to run against anything but localhost. There is no command that resets the Render database, deliberately.
- The runner wraps each file in its own transaction together with its `schema_migrations` row, so don't put `BEGIN`/`COMMIT` in migration files, and don't use statements that can't run inside a transaction (e.g. `CREATE INDEX CONCURRENTLY`).
- Read-only inspection with `psql` (e.g. `\d recordings`, `SELECT ...`) is fine and encouraged for debugging. The rule is specifically about **mutations**.
- Follow the style and conventions of the official PostgreSQL manual for all migration SQL: uppercase keywords, lowercase `snake_case` identifiers, canonical type names (`TEXT`, `BIGINT`, `TIMESTAMPTZ`, `REAL`), and aligned column definitions. When in doubt about formatting a construct, check how the Postgres docs format the equivalent.
- Migration files use the `YYYYMMDDHHMMSS_short_description.sql` naming scheme so they apply in order. Each file should start with a comment block describing the intent of the migration and any non-obvious decisions.

## Database Access Model

- **The Next.js server is the only thing that talks to Postgres.** It connects through the `pg` pool in `web/lib/db/client.ts` using `DATABASE_URL`, which Render wires to koom-db's internal (private-network) connection string via `fromDatabase` in `render.yaml`. There is no auto-generated REST/GraphQL layer and no browser-to-database path; if you ever have the urge to add one, stop and ask first.
- TLS is driven by the connection string. The internal Render URL and the local Docker URL are plaintext; tooling that uses koom-db's external URL from a dev machine (the doctor's `RENDER_DATABASE_URL`) connects over TLS, which Render requires for external connections.

## Commands

- Build app bundle: `./scripts/build-app.sh`
- Run app in foreground: `./scripts/run.sh`
