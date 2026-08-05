-- Read-only /v1/responses first-output governance report.
--
-- Usage with a read replica or a guarded psql session:
--   psql "$DATABASE_URL" -v window='1 hour' -f deploy/stream-attempts-report.sql
--   psql "$DATABASE_URL" -v window='24 hours' -f deploy/stream-attempts-report.sql
--
-- Do not run broad JSON scans on the production primary. The query is scoped
-- to the requested window and the stream_attempts component.

\if :{?window}
\else
  \set window '1 hour'
\endif

WITH stream_attempts AS (
  SELECT
    created_at,
    COALESCE(extra ->> 'client_type', 'unknown') AS client_type,
    COALESCE(extra ->> 'model', 'unknown') AS model,
    COALESCE(extra ->> 'reasoning_effort', 'unspecified') AS reasoning_effort,
    COALESCE(extra ->> 'selected_account_id', '0') AS selected_account_id,
    COALESCE(extra ->> 'request_body_bucket', 'unknown') AS request_body_bucket,
    extra ->> 'cancel_phase' AS cancel_phase,
    NULLIF(extra ->> 'upstream_response_headers_ms', '')::double precision AS upstream_response_headers_ms,
    NULLIF(extra ->> 'first_semantic_event_ms', '')::double precision AS first_semantic_event_ms,
    NULLIF(extra ->> 'first_downstream_byte_ms', '')::double precision AS first_downstream_byte_ms,
    NULLIF(extra ->> 'max_downstream_idle_after_headers_ms', '')::double precision AS max_downstream_idle_after_headers_ms,
    COALESCE(NULLIF(extra ->> 'downstream_keepalive_count', '')::bigint, 0) AS downstream_keepalive_count
  FROM ops_system_logs
  WHERE component = 'stream_attempts'
    AND message = 'stream_attempt.completed'
    AND created_at >= now() - (:'window')::interval
)
SELECT
  min(created_at) AS window_start,
  max(created_at) AS window_end,
  client_type,
  model,
  reasoning_effort,
  selected_account_id,
  request_body_bucket,
  count(*) AS request_count,
  count(first_semantic_event_ms) AS semantic_output_count,
  round(percentile_cont(0.95) WITHIN GROUP (ORDER BY first_semantic_event_ms)::numeric, 1) AS ttft_p95_ms,
  round(percentile_cont(0.99) WITHIN GROUP (ORDER BY first_semantic_event_ms)::numeric, 1) AS ttft_p99_ms,
  round(percentile_cont(0.95) WITHIN GROUP (ORDER BY upstream_response_headers_ms)::numeric, 1) AS upstream_headers_p95_ms,
  round(percentile_cont(0.95) WITHIN GROUP (ORDER BY first_downstream_byte_ms)::numeric, 1) AS downstream_first_byte_p95_ms,
  round(percentile_cont(0.95) WITHIN GROUP (ORDER BY max_downstream_idle_after_headers_ms)::numeric, 1) AS downstream_idle_after_headers_p95_ms,
  max(max_downstream_idle_after_headers_ms) AS downstream_idle_after_headers_max_ms,
  count(*) FILTER (
    WHERE cancel_phase IN ('before_upstream_headers', 'after_headers_before_semantic')
  ) AS presemantic_cancel_count,
  round(
    100.0 * count(*) FILTER (
      WHERE cancel_phase IN ('before_upstream_headers', 'after_headers_before_semantic')
    ) / NULLIF(count(*), 0),
    3
  ) AS presemantic_cancel_rate_pct,
  sum(downstream_keepalive_count) AS downstream_keepalive_count
FROM stream_attempts
GROUP BY
  client_type,
  model,
  reasoning_effort,
  selected_account_id,
  request_body_bucket
ORDER BY request_count DESC, client_type, model;
