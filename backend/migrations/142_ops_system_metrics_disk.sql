-- Ops Monitoring: add disk usage fields to minute-level system snapshots.
-- Nullable columns keep existing rows and older collectors compatible.

ALTER TABLE ops_system_metrics
  ADD COLUMN IF NOT EXISTS disk_used_mb BIGINT,
  ADD COLUMN IF NOT EXISTS disk_total_mb BIGINT,
  ADD COLUMN IF NOT EXISTS disk_usage_percent DOUBLE PRECISION;

COMMENT ON COLUMN ops_system_metrics.disk_used_mb IS 'Disk space used by the gateway runtime filesystem, in MB.';
COMMENT ON COLUMN ops_system_metrics.disk_total_mb IS 'Total disk space visible to the gateway runtime filesystem, in MB.';
COMMENT ON COLUMN ops_system_metrics.disk_usage_percent IS 'Disk usage percentage for the gateway runtime filesystem.';
