package repository

import (
	"context"
	"database/sql/driver"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestOpsRepositorySystemMetricsPersistsDiskStats(t *testing.T) {
	db, mock := newSQLMock(t)
	repo := &opsRepository{db: db}

	createdAt := time.Date(2026, 6, 13, 10, 30, 0, 0, time.UTC)
	diskUsedMB := int64(2048)
	diskTotalMB := int64(4096)
	diskPct := 50.0

	args := []driver.Value{
		createdAt,
		int64(1),
		nil,
		nil,
		int64(0),
		int64(0),
		int64(0),
		int64(0),
		int64(0),
		int64(0),
		int64(0),
		int64(0),
		int64(0),
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		diskUsedMB,
		diskTotalMB,
		diskPct,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
	}
	mock.ExpectExec(`INSERT INTO ops_system_metrics \([\s\S]*disk_used_mb,[\s\S]*disk_total_mb,[\s\S]*disk_usage_percent`).
		WithArgs(args...).
		WillReturnResult(sqlmock.NewResult(0, 1))

	err := repo.InsertSystemMetrics(context.Background(), &service.OpsInsertSystemMetricsInput{
		CreatedAt:        createdAt,
		WindowMinutes:    1,
		DiskUsedMB:       &diskUsedMB,
		DiskTotalMB:      &diskTotalMB,
		DiskUsagePercent: &diskPct,
	})
	require.NoError(t, err)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestOpsRepositoryGetLatestSystemMetricsMapsDiskStats(t *testing.T) {
	db, mock := newSQLMock(t)
	repo := &opsRepository{db: db}

	createdAt := time.Date(2026, 6, 13, 10, 31, 0, 0, time.UTC)
	rows := sqlmock.NewRows([]string{
		"id",
		"created_at",
		"window_minutes",
		"cpu_usage_percent",
		"memory_used_mb",
		"memory_total_mb",
		"memory_usage_percent",
		"disk_used_mb",
		"disk_total_mb",
		"disk_usage_percent",
		"db_ok",
		"redis_ok",
		"redis_conn_total",
		"redis_conn_idle",
		"db_conn_active",
		"db_conn_idle",
		"db_conn_waiting",
		"goroutine_count",
		"concurrency_queue_depth",
		"account_switch_count",
	}).AddRow(
		int64(7),
		createdAt,
		1,
		12.5,
		int64(512),
		int64(1024),
		50.0,
		int64(2048),
		int64(4096),
		50.0,
		true,
		true,
		4,
		2,
		3,
		5,
		0,
		88,
		1,
		int64(6),
	)

	mock.ExpectQuery(`SELECT[\s\S]*disk_used_mb,[\s\S]*disk_total_mb,[\s\S]*disk_usage_percent[\s\S]*FROM ops_system_metrics`).
		WithArgs(1).
		WillReturnRows(rows)

	out, err := repo.GetLatestSystemMetrics(context.Background(), 1)
	require.NoError(t, err)
	require.NotNil(t, out)
	require.NotNil(t, out.DiskUsedMB)
	require.Equal(t, int64(2048), *out.DiskUsedMB)
	require.NotNil(t, out.DiskTotalMB)
	require.Equal(t, int64(4096), *out.DiskTotalMB)
	require.NotNil(t, out.DiskUsagePercent)
	require.InDelta(t, 50.0, *out.DiskUsagePercent, 0.0001)
	require.NoError(t, mock.ExpectationsWereMet())
}
