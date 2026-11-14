-- 20261114174600_create_device_tokens.sql
--
-- Replaces the deployment-wide KOOM_ADMIN_SECRET bearer credential
-- with per-device tokens. The browser admin signs in with Google; the
-- desktop app signs in through that same browser flow and receives a
-- long-lived bearer token minted for that one device.
--
-- Design notes:
--
--   - Only a SHA-256 hash of each token is stored. Tokens are 256-bit
--     random values, so an unsalted fast hash is sufficient: there is
--     no dictionary to attack, and lookups stay a single indexed
--     equality match.
--
--   - `email` records which allowlisted Google account minted the
--     token. Every request re-checks it against KOOM_ADMIN_EMAILS, so
--     removing an address from the allowlist revokes all of that
--     account's devices without touching this table.
--
--   - `label` is the device name the desktop app reported (its
--     hostname), shown to the admin when confirming the sign-in and
--     useful when revoking a device by hand.
--
--   - `last_used_at` is updated on every authenticated request so a
--     stale device is easy to spot.

CREATE TABLE device_tokens (
    id           TEXT PRIMARY KEY,
    token_hash   TEXT NOT NULL UNIQUE,
    email        TEXT NOT NULL,
    label        TEXT NOT NULL CHECK (char_length(label) BETWEEN 1 AND 200),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ
);
