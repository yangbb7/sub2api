-- 228_ops_alert_noise_governance.sql
--
-- Alert policy must reflect sustained, user-visible availability impact rather
-- than one-off failures during a low-traffic minute. The three original rate
-- rules were mathematically overlapping and generated multiple P0/P1 emails
-- for the same handful of requests.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '10min';

-- Keep the low-success-rate rule as a long-window dashboard trend. It is not
-- page-worthy because the error-rate rules express the same signal directly.
UPDATE ops_alert_rules
SET
  enabled = true,
  severity = 'P2',
  threshold = 95.0,
  window_minutes = 60,
  sustained_minutes = 30,
  cooldown_minutes = 180,
  notify_email = false,
  filters = COALESCE(filters, '{}'::jsonb) ||
    '{"min_sla_requests":200,"min_sla_errors":10}'::jsonb,
  description = '近 60 分钟 SLA 成功率低于 95%、至少 200 个 SLA 请求且至少 10 个错误时记录趋势事件；不发送邮件。',
  updated_at = NOW()
WHERE name = '成功率过低' AND metric_type = 'success_rate';

-- Keep moderate failures visible in the dashboard without paging. A rate only
-- becomes meaningful when both denominator and error count are sufficient.
UPDATE ops_alert_rules
SET
  severity = 'P2',
  threshold = 10.0,
  window_minutes = 15,
  sustained_minutes = 10,
  cooldown_minutes = 60,
  notify_email = false,
  filters = COALESCE(filters, '{}'::jsonb) ||
    '{"min_sla_requests":30,"min_sla_errors":5}'::jsonb,
  description = '15 分钟内 SLA 错误率超过 10%、至少 30 个 SLA 请求且至少 5 个错误时记录趋势事件；不发送邮件。',
  updated_at = NOW()
WHERE name = '错误率过高' AND metric_type = 'error_rate';

-- There is one and only one request-rate email page: sustained, broad failure.
UPDATE ops_alert_rules
SET
  severity = 'P0',
  threshold = 25.0,
  window_minutes = 15,
  sustained_minutes = 10,
  cooldown_minutes = 60,
  notify_email = true,
  filters = COALESCE(filters, '{}'::jsonb) ||
    '{"min_sla_requests":30,"min_sla_errors":10}'::jsonb,
  description = '15 分钟内 SLA 错误率超过 25%、至少 30 个 SLA 请求且至少 10 个错误，并持续 10 分钟时发送 P0 邮件。',
  updated_at = NOW()
WHERE name = '错误率极高' AND metric_type = 'error_rate';

-- The prior policy left three independently firing events in flight. Resolve
-- them so the new policy starts from a clean incident boundary.
UPDATE ops_alert_events
SET status = 'manual_resolved', resolved_at = NOW()
WHERE status = 'firing'
  AND rule_id IN (
    SELECT id
    FROM ops_alert_rules
    WHERE name IN ('成功率过低', '错误率过高', '错误率极高')
  );

-- Limit global mail fan-out. P0/P1 incidents remain recorded in the dashboard;
-- this caps inbox noise if several independent rules happen to fire together.
INSERT INTO settings (key, value, updated_at)
VALUES (
  'ops_email_notification_config',
  '{"alert":{"enabled":true,"recipients":[],"min_severity":"","rate_limit_per_hour":2,"batching_window_seconds":0,"include_resolved_alerts":false},"report":{"enabled":false,"recipients":[]}}',
  NOW()
)
ON CONFLICT (key) DO UPDATE
SET
  value = jsonb_set(
    COALESCE(NULLIF(settings.value, ''), '{}')::jsonb,
    '{alert}',
    COALESCE(COALESCE(NULLIF(settings.value, ''), '{}')::jsonb -> 'alert', '{}'::jsonb)
      || jsonb_build_object('rate_limit_per_hour', 2),
    true
  )::text,
  updated_at = NOW();
