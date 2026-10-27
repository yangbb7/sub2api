-- PostgreSQL LEAST ignores NULL deleted_at, so live rows use expire_time.
-- Pending mutation tokens (including stale leases) remain owned by recovery.
CREATE INDEX IF NOT EXISTS idx_gemini_cached_contents_retention
    ON gemini_cached_contents (LEAST(expire_time, deleted_at), id)
    WHERE mutation_token IS NULL;
