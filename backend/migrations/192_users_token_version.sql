-- Persist the raw per-user epoch used to invalidate access and refresh tokens.
-- JWT claims keep XORing this epoch with the legacy email/password fingerprint;
-- default zero therefore preserves pre-migration tokens instead of logging everyone out.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS token_version BIGINT NOT NULL DEFAULT 0;
