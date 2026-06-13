package service

import (
	"context"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
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

func TestOpsMetricsCollectorLeaderLockIsStickyForActiveInstance(t *testing.T) {
	t.Parallel()

	fake := newFakeOpsLeaderRedis()
	ctx := context.Background()
	collector := &OpsMetricsCollector{
		redisLeaderLocker: fake,
		instanceID:        "new-container",
		startedAt:         time.Unix(200, 0),
	}

	release, ok := collector.tryAcquireLeaderLock(ctx)
	require.True(t, ok)
	require.Nil(t, release)
	require.Equal(t, "200000000000:new-container", fake.value)

	release, ok = collector.tryAcquireLeaderLock(ctx)
	require.True(t, ok)
	require.Nil(t, release)
	require.Equal(t, 1, fake.setCalls)

	other := &OpsMetricsCollector{
		redisLeaderLocker: fake,
		instanceID:        "old-container",
		startedAt:         time.Unix(100, 0),
	}
	release, ok = other.tryAcquireLeaderLock(ctx)
	require.False(t, ok)
	require.Nil(t, release)
	require.Equal(t, "200000000000:new-container", fake.value)
}

func TestOpsMetricsCollectorLeaderLockNewerInstanceTakesOver(t *testing.T) {
	t.Parallel()

	fake := newFakeOpsLeaderRedis()
	ctx := context.Background()
	oldInstance := &OpsMetricsCollector{
		redisLeaderLocker: fake,
		instanceID:        "old-container",
		startedAt:         time.Unix(100, 0),
	}
	newInstance := &OpsMetricsCollector{
		redisLeaderLocker: fake,
		instanceID:        "new-container",
		startedAt:         time.Unix(200, 0),
	}

	release, ok := oldInstance.tryAcquireLeaderLock(ctx)
	require.True(t, ok)
	require.Nil(t, release)
	require.Equal(t, "100000000000:old-container", fake.value)

	release, ok = newInstance.tryAcquireLeaderLock(ctx)
	require.True(t, ok)
	require.Nil(t, release)
	require.Equal(t, "200000000000:new-container", fake.value)

	release, ok = oldInstance.tryAcquireLeaderLock(ctx)
	require.False(t, ok)
	require.Nil(t, release)
}

type fakeOpsLeaderRedis struct {
	value    string
	setCalls int
}

func newFakeOpsLeaderRedis() *fakeOpsLeaderRedis {
	return &fakeOpsLeaderRedis{}
}

func (f *fakeOpsLeaderRedis) Set(ctx context.Context, key string, value any, expiration time.Duration) error {
	f.setCalls++
	f.value = value.(string)
	return nil
}

func (f *fakeOpsLeaderRedis) SetNX(ctx context.Context, key string, value any, expiration time.Duration) (bool, error) {
	if f.value != "" {
		return false, nil
	}
	f.value = value.(string)
	return true, nil
}

func (f *fakeOpsLeaderRedis) Get(ctx context.Context, key string) (string, error) {
	if f.value == "" {
		return "", redis.Nil
	}
	return f.value, nil
}
