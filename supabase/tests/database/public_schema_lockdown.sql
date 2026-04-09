-- supabase/tests/database/public_schema_lockdown.sql
--
-- Security invariants for the public schema. Run after every
-- migration (both local and CI) to catch any regression that
-- accidentally re-exposes koom data to PostgREST / pg_graphql
-- role switches.
--
-- This file is plain SQL — no pgTAP, no extension — so it runs
-- identically against the local Supabase stack (port 54322) and
-- against the CI postgres service container (port 5432). Each
-- check is a DO block that queries the catalog and uses
-- `RAISE EXCEPTION` to fail loudly when an invariant is violated.
-- Error messages always include the offending object names so
-- CI output points directly at the problem.
--
-- Exit semantics: psql run with `-v ON_ERROR_STOP=1 -f <this>`
-- exits nonzero on the first RAISE EXCEPTION, which fails the
-- CI step or the local `npm run db:verify` call.
--
-- Adding a new invariant: append a new DO block below. Each
-- check is independent — they don't share state — so the order
-- within the file is purely for readability.
--
-- Deliberately NOT checking:
--   - Tables in non-public schemas (auth, storage, realtime,
--     graphql, graphql_public, supabase_*, vault, extensions).
--     These are Supabase-managed and have their own ACLs that
--     koom should not second-guess.
--   - The `anon` and `authenticated` keys themselves — they're
--     public by design and their rotation is out of scope here.
--   - PostgREST's "exposed schemas" project setting — that's
--     dashboard config, not DB state, and needs a separate
--     check via the Supabase Management API.

\echo 'Verifying public schema lockdown invariants...'

-- ────────────────────────────────────────────────────────────
-- 1. Every table in public must have RLS enabled.
-- ────────────────────────────────────────────────────────────
-- Catches: ALTER TABLE ... DISABLE ROW LEVEL SECURITY, or the
-- auto-lockdown event trigger failing to fire on a new table.

DO $$
DECLARE
    offending text;
BEGIN
    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY c.relname)
      INTO offending
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r', 'p')
       AND c.relrowsecurity = false;

    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'lockdown: table(s) in public have RLS disabled: %', offending;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- 2. The `anon` role must hold zero table-level grants in public.
-- ────────────────────────────────────────────────────────────
-- Catches: GRANT SELECT/INSERT/UPDATE/DELETE/etc ON public.foo
-- TO anon — whether deliberate or a copy-paste from a Supabase
-- tutorial that assumed a different access model.

DO $$
DECLARE
    offending text;
BEGIN
    SELECT string_agg(
               format('%I (%s)', table_name, privilege_type),
               ', '
               ORDER BY table_name, privilege_type
           )
      INTO offending
      FROM information_schema.role_table_grants
     WHERE table_schema = 'public'
       AND grantee = 'anon';

    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'lockdown: anon has table grants in public: %', offending;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- 3. The `authenticated` role must hold zero table-level grants
--    in public. Same reasoning as anon, one level of auth up.
-- ────────────────────────────────────────────────────────────

DO $$
DECLARE
    offending text;
BEGIN
    SELECT string_agg(
               format('%I (%s)', table_name, privilege_type),
               ', '
               ORDER BY table_name, privilege_type
           )
      INTO offending
      FROM information_schema.role_table_grants
     WHERE table_schema = 'public'
       AND grantee = 'authenticated';

    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'lockdown: authenticated has table grants in public: %', offending;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- 4. Neither anon nor authenticated may hold USAGE/SELECT/UPDATE
--    on any sequence in public, nor EXECUTE on any function in
--    public. Uses pg_class.relacl / pg_proc.proacl directly via
--    aclexplode() because information_schema.usage_privileges
--    has version-dependent quirks.
-- ────────────────────────────────────────────────────────────

DO $$
DECLARE
    offending text;
BEGIN
    SELECT string_agg(
               format('sequence %I.%I granted to %I (%s)',
                      n.nspname, c.relname,
                      acl.grantee::regrole::text,
                      acl.privilege_type),
               ', '
               ORDER BY c.relname
           )
      INTO offending
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      CROSS JOIN LATERAL aclexplode(c.relacl) acl
     WHERE n.nspname = 'public'
       AND c.relkind = 'S'
       AND acl.grantee::regrole::text IN ('anon', 'authenticated');

    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'lockdown: anon/authenticated have sequence grants in public: %', offending;
    END IF;
END $$;

DO $$
DECLARE
    offending text;
BEGIN
    SELECT string_agg(
               format('function %I.%I granted to %I (%s)',
                      n.nspname, p.proname,
                      acl.grantee::regrole::text,
                      acl.privilege_type),
               ', '
               ORDER BY p.proname
           )
      INTO offending
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      CROSS JOIN LATERAL aclexplode(p.proacl) acl
     WHERE n.nspname = 'public'
       AND acl.grantee::regrole::text IN ('anon', 'authenticated');

    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'lockdown: anon/authenticated have function grants in public: %', offending;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- 5. No RLS policies are defined on any table in public.
-- ────────────────────────────────────────────────────────────
-- koom deliberately uses zero RLS policies — the only
-- intended data path is the direct `pg` pool as `postgres`,
-- which has BYPASSRLS. A policy showing up here almost always
-- means someone copy-pasted a Supabase tutorial snippet that
-- assumed a different access model. If a policy is genuinely
-- desired in the future, update this check to allowlist the
-- specific policy name rather than permitting any policy.

DO $$
DECLARE
    offending text;
BEGIN
    SELECT string_agg(
               format('%I.%I (%s on %I)',
                      schemaname, tablename,
                      policyname, cmd),
               ', '
               ORDER BY tablename, policyname
           )
      INTO offending
      FROM pg_policies
     WHERE schemaname = 'public';

    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'lockdown: RLS policies found in public (koom uses none by design): %', offending;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- 6. The auto-lockdown event trigger is installed and enabled.
-- ────────────────────────────────────────────────────────────
-- Catches: someone DROPs the function or event trigger,
-- disables it, or changes ownership. Losing the trigger
-- silently re-opens the footgun on the next CREATE TABLE.

DO $$
DECLARE
    trigger_state "char";
BEGIN
    SELECT evtenabled
      INTO trigger_state
      FROM pg_event_trigger
     WHERE evtname = 'koom_lock_down_new_public_tables';

    IF trigger_state IS NULL THEN
        RAISE EXCEPTION 'lockdown: koom_lock_down_new_public_tables event trigger is missing';
    END IF;

    IF trigger_state <> 'O' THEN
        RAISE EXCEPTION 'lockdown: koom_lock_down_new_public_tables event trigger exists but is not enabled (state=%)', trigger_state;
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- 7. The pg_graphql extension must not be installed.
-- ────────────────────────────────────────────────────────────
-- Catches: someone reinstalls pg_graphql. The extension gives
-- GraphQL a live introspection path into whatever anon/
-- authenticated can see; removing it is the simplest way to
-- be sure /graphql/v1 has nothing to serve.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_graphql') THEN
        RAISE EXCEPTION 'lockdown: pg_graphql extension is installed (koom does not use GraphQL)';
    END IF;
END $$;

-- ────────────────────────────────────────────────────────────
-- 8. Every view in public must have security_invoker=true.
-- ────────────────────────────────────────────────────────────
-- Catches: a view that bypasses RLS on its underlying tables.
-- Views are `security_definer` by default in Postgres, which
-- means they run with the permissions of the view owner
-- (typically postgres, which has BYPASSRLS) — so a view on an
-- RLS-protected table silently serves all rows to anyone who
-- can query the view. Supabase's docs specifically flag this:
-- https://supabase.com/docs/guides/database/postgres/row-level-security#views
-- security_invoker=true makes the view honor the caller's RLS.

DO $$
DECLARE
    offending text;
BEGIN
    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY c.relname)
      INTO offending
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind = 'v'
       AND NOT COALESCE(
           (SELECT bool_or(opt = 'security_invoker=true')
              FROM unnest(c.reloptions) opt),
           false
       );

    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'lockdown: view(s) in public lack security_invoker=true (would bypass RLS): %', offending;
    END IF;
END $$;

\echo 'All public schema lockdown invariants satisfied.'
