-- Keep user-scoped alert silences bound to the user that produced the event.
ALTER TABLE ops_alert_silences
    ADD COLUMN IF NOT EXISTS user_id BIGINT;

CREATE INDEX IF NOT EXISTS idx_ops_alert_silences_lookup_v2
    ON ops_alert_silences (rule_id, platform, group_id, user_id, region, until);
