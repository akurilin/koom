-- 20260410090400_create_comments.sql
--
-- Adds a timestamped comment system to koom. Two tables:
--
--   commenters — anonymous viewer identities, one row per unique
--                browser (identified by a koom-commenter HttpOnly
--                cookie holding the id). Display names are NOT
--                stored; they're derived at read time as
--                "Guest " + first-4-hex-chars-of-id.
--
--   comments   — one comment per row, anchored to a specific point
--                in a recording's timeline via timestamp_seconds.
--                Every comment is either anonymous (commenter_id
--                set, is_admin false) or admin (commenter_id null,
--                is_admin true). The XOR is enforced by a CHECK
--                constraint.
--
-- Design notes:
--
--   - ON DELETE CASCADE from recordings: deleting a recording
--     auto-removes all its comments. No orphaned comment rows.
--
--   - No foreign key from comments.commenter_id to commenters.id.
--     We don't delete commenters in the MVP, so the FK would add
--     write-path overhead without practical value. The XOR check
--     constraint is the real invariant.
--
--   - timestamp_seconds is NOT NULL because koom only supports
--     timestamped comments (no general/untimed comments). REAL
--     matches the type used for recordings.duration_seconds.
--
--   - The composite index covers the only listing query shape:
--     WHERE recording_id = $1 ORDER BY timestamp_seconds, created_at.
--
--   - Body CHECK allows up to 4000 chars at the DB level; the API
--     validates at 2000. The headroom lets us relax the API limit
--     later without a migration.
--
--   - Both tables land in public and are automatically locked down
--     by the koom_lock_down_new_public_tables DDL event trigger
--     (RLS enabled, no grants to anon/authenticated). The app
--     connects as postgres with BYPASSRLS, so no policies needed.

CREATE TABLE commenters (
    id         TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE comments (
    id                TEXT PRIMARY KEY,
    recording_id      TEXT NOT NULL REFERENCES recordings (id) ON DELETE CASCADE,
    commenter_id      TEXT,
    is_admin          BOOLEAN NOT NULL DEFAULT FALSE,
    body              TEXT NOT NULL CHECK (char_length(body) BETWEEN 1 AND 4000),
    timestamp_seconds REAL NOT NULL CHECK (timestamp_seconds >= 0),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT comments_identity_xor CHECK (
        (is_admin AND commenter_id IS NULL)
        OR (NOT is_admin AND commenter_id IS NOT NULL)
    )
);

CREATE INDEX comments_recording_timeline_idx
    ON comments (recording_id, timestamp_seconds, created_at);
