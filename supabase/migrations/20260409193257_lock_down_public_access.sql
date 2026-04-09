-- 20260409193257_lock_down_public_access.sql
--
-- Lock down every public.* table against unauthenticated access via
-- Supabase's auto-exposed PostgREST, pg_graphql, and Realtime APIs,
-- and make that lockdown the permanent default for every future
-- table rather than a per-migration discipline.
--
-- Context:
--   Supabase stands up PostgREST at <project>.supabase.co/rest/v1
--   and pg_graphql at /graphql/v1 alongside every project, routed
--   to the database via role-switching into `anon` (no JWT) or
--   `authenticated` (with JWT) based on the `apikey` header. At
--   project creation Supabase pre-seeds ALTER DEFAULT PRIVILEGES
--   that auto-grants full CRUD (SELECT/INSERT/UPDATE/DELETE/
--   REFERENCES/TRIGGER/TRUNCATE) to both roles on any table
--   created later in the public schema, and tables created via
--   raw SQL (as ours are, through `supabase db push`) do NOT have
--   Row Level Security enabled by default. Combined, that means
--   every newly-created public.* table is fully readable and
--   writable from the internet with just the publicly-shipped
--   anon key — whose security model explicitly assumes you
--   compensated with RLS.
--
--   koom deliberately does not use PostgREST, pg_graphql, or
--   Supabase Auth. It connects to Postgres directly through the
--   pg pool as the table-owning `postgres` role, which holds
--   `BYPASSRLS`, so enabling RLS without any policies denies the
--   API role-switches entirely while leaving the app's direct
--   connection fully functional.
--
-- What this migration does, in order:
--
--   1. Retroactively lock down the existing `recordings` table
--      (ENABLE RLS + REVOKE grants from anon/authenticated).
--
--   2. Flip the default privileges for public tables, sequences,
--      and functions created by `postgres` so the auto-grant to
--      anon/authenticated simply doesn't fire for future objects.
--      `supabase db push` connects as `postgres`, so this covers
--      every migration-driven CREATE going forward. (It does not
--      touch the parallel `FOR ROLE supabase_admin` defaults —
--      those only fire when the dashboard or an internal Supabase
--      process creates tables, and CLAUDE.md forbids using the
--      dashboard for DDL anyway.)
--
--   3. Drop the `pg_graphql` extension entirely. koom doesn't use
--      GraphQL, so removing the extension is strictly better than
--      starving it of grants: fewer moving parts, smaller attack
--      surface, and the /graphql/v1 endpoint has literally nothing
--      to resolve against. Reversible with `CREATE EXTENSION
--      pg_graphql;` — Supabase keeps it on the approved list.
--
--   4. Install a DDL event trigger that automatically runs
--      `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` on every new
--      public.* table. Step 2 blocks the grant path, step 4 blocks
--      the policy path — together they make the two separate
--      layers of defense that PostgREST relies on both deny-by-
--      default.
--
--      The trigger's function follows Supabase's officially-
--      recommended pattern: SECURITY DEFINER with
--      `SET search_path = pg_catalog` to prevent search-path
--      injection, per-table exception handling so one failing
--      ALTER doesn't break a multi-table migration, RAISE LOG for
--      observability, and a wide command_tag / object_type match
--      so CREATE TABLE AS, SELECT INTO, and partitioned tables
--      are caught alongside plain CREATE TABLE.
--
--      The function and trigger are namespaced with the `koom_`
--      prefix so they're visibly distinct from the upstream
--      Supabase-owned event triggers (graphql_watch_ddl,
--      pgrst_ddl_watch, etc.). If you copy an updated version of
--      this pattern from Supabase's docs in the future to keep
--      us current, remember to re-apply the `koom_` prefix to
--      both the function name and the event trigger name.
--
-- How to deliberately opt a future table BACK IN to PostgREST or
-- pg_graphql (if this ever becomes desirable):
--
--   CREATE TABLE public.exposed_view (...);
--   -- Undo the auto-lockdown in the same migration:
--   ALTER TABLE public.exposed_view DISABLE ROW LEVEL SECURITY;
--   GRANT SELECT ON TABLE public.exposed_view TO anon, authenticated;
--
-- Making exposure a conscious, reviewable opt-in in the same
-- migration file is the whole point of flipping the default.

-- ────────────────────────────────────────────────────────────────
-- 1. Retroactively lock down the existing recordings table.
-- ────────────────────────────────────────────────────────────────

ALTER TABLE public.recordings ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.recordings FROM anon, authenticated;

-- ────────────────────────────────────────────────────────────────
-- 2. Strip the Supabase auto-grant from FOR ROLE postgres defaults
--    so future tables, sequences, and functions in public aren't
--    auto-exposed to anon / authenticated.
-- ────────────────────────────────────────────────────────────────

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON TABLES FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON SEQUENCES FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON FUNCTIONS FROM anon, authenticated;

-- ────────────────────────────────────────────────────────────────
-- 3. Drop pg_graphql entirely. koom has no GraphQL code path.
-- ────────────────────────────────────────────────────────────────
--
-- CASCADE removes the extension's event triggers
-- (graphql_watch_ddl, graphql_watch_drop), resolver functions in
-- the `graphql` and `graphql_public` schemas, and the dependent
-- sequence. IF EXISTS keeps the migration idempotent so
-- re-running it on an environment that already dropped the
-- extension (or a fresh local stack where something changed
-- upstream) doesn't fail.

DROP EXTENSION IF EXISTS pg_graphql CASCADE;

-- ────────────────────────────────────────────────────────────────
-- 4. Install the auto-enable-RLS event trigger.
-- ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION koom_lock_down_new_public_table()
RETURNS EVENT_TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    cmd record;
BEGIN
    FOR cmd IN
        SELECT schema_name, object_identity, object_type
        FROM pg_event_trigger_ddl_commands()
        WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
          AND object_type IN ('table', 'partitioned table')
    LOOP
        IF cmd.schema_name = 'public' THEN
            BEGIN
                EXECUTE format(
                    'ALTER TABLE IF EXISTS %s ENABLE ROW LEVEL SECURITY',
                    cmd.object_identity
                );
                RAISE LOG
                    'koom_lock_down_new_public_table: enabled RLS on %',
                    cmd.object_identity;
            EXCEPTION
                WHEN OTHERS THEN
                    RAISE LOG
                        'koom_lock_down_new_public_table: failed to enable RLS on %: %',
                        cmd.object_identity, SQLERRM;
            END;
        END IF;
    END LOOP;
END;
$$;

-- Drop-then-create so re-running this migration against an
-- environment that already has the trigger (e.g. a local stack
-- with partial history) doesn't fail on the duplicate.
DROP EVENT TRIGGER IF EXISTS koom_lock_down_new_public_tables;

CREATE EVENT TRIGGER koom_lock_down_new_public_tables
    ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
    EXECUTE FUNCTION koom_lock_down_new_public_table();
