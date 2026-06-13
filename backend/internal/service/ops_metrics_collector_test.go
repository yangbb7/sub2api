package service

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestOpsMetricsCollectorCollectSystemStatsIncludesDisk(t *testing.T) {
	collector := &OpsMetricsCollector{}

	stats, err := collector.collectSystemStats(context.Background())
	require.NoError(t, err)
	require.NotNil(t, stats)
	require.NotNil(t, stats.diskUsedMB)
	require.NotNil(t, stats.diskTotalMB)
	require.NotNil(t, stats.diskUsagePercent)
	require.GreaterOrEqual(t, *stats.diskUsedMB, int64(0))
	require.Greater(t, *stats.diskTotalMB, int64(0))
	require.GreaterOrEqual(t, *stats.diskUsagePercent, 0.0)
	require.LessOrEqual(t, *stats.diskUsagePercent, 100.0)
}
