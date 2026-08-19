package service

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/gin-gonic/gin"
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

func TestWriteOpenAIFastPolicyBlockedResponseMarksBusinessLimited(t *testing.T) {
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)

	writeOpenAIFastPolicyBlockedResponse(c, &OpenAIFastBlockedError{Message: "custom fast policy block"})

	require.Equal(t, http.StatusForbidden, rec.Code)
	require.True(t, HasOpsClientBusinessLimited(c))
	reason, ok := c.Get(OpsClientBusinessLimitedReasonKey)
	require.True(t, ok)
	require.Equal(t, OpsClientBusinessLimitedReasonLocalPolicyDenied, reason)
}

func TestOpsMetricsCollectorQueryErrorCountsExcludesCountTokens(t *testing.T) {
	db, mock, err := sqlmock.New()
	require.NoError(t, err)

	collector := &OpsMetricsCollector{db: db}
	start := time.Date(2026, 5, 26, 10, 0, 0, 0, time.UTC)
	end := start.Add(time.Hour)

	mock.ExpectQuery(`(?s)COALESCE\(error_owner, ''\) <> 'client'.*FROM ops_error_logs\s+WHERE created_at >= \$1 AND created_at < \$2\s+AND is_count_tokens = FALSE`).
		WithArgs(start, end).
		WillReturnRows(sqlmock.NewRows([]string{
			"error_total",
			"business_limited",
			"error_sla",
			"upstream_excl",
			"upstream_429",
			"upstream_529",
		}).AddRow(int64(5), int64(2), int64(3), int64(1), int64(1), int64(1)))

	errorTotal, businessLimited, errorSLA, upstreamExcl429529, upstream429, upstream529, err := collector.queryErrorCounts(context.Background(), start, end)
	require.NoError(t, err)
	require.Equal(t, int64(5), errorTotal)
	require.Equal(t, int64(2), businessLimited)
	require.Equal(t, int64(3), errorSLA)
	require.Equal(t, int64(1), upstreamExcl429529)
	require.Equal(t, int64(1), upstream429)
	require.Equal(t, int64(1), upstream529)
	require.NoError(t, mock.ExpectationsWereMet())
	mock.ExpectClose()
	require.NoError(t, db.Close())
	require.NoError(t, mock.ExpectationsWereMet())
}
