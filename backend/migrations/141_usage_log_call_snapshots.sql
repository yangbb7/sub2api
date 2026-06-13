-- Store sanitized, length-limited request/response previews for user-facing usage details.
-- Raw credentials and unbounded payloads must be removed before values reach these columns.
ALTER TABLE usage_logs
	ADD COLUMN IF NOT EXISTS request_snapshot JSONB,
	ADD COLUMN IF NOT EXISTS response_snapshot JSONB;

COMMENT ON COLUMN usage_logs.request_snapshot IS 'Sanitized user-visible request preview with generation parameters and secrets removed.';
COMMENT ON COLUMN usage_logs.response_snapshot IS 'Sanitized user-visible response preview with secrets removed and content length capped.';
