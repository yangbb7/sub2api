package repository

import (
	"context"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func newOpsAlertSilenceRepoMock(t *testing.T) (*opsRepository, sqlmock.Sqlmock) {
	t.Helper()
	db, mock, err := sqlmock.New()
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return &opsRepository{db: db}, mock
}

func TestCreateAlertSilence_AllowsEmptyPlatform(t *testing.T) {
	repo, mock := newOpsAlertSilenceRepoMock(t)
	until := time.Date(2026, time.July, 15, 12, 0, 0, 0, time.UTC)
	createdAt := until.Add(-time.Minute)

	mock.ExpectQuery("INSERT INTO ops_alert_silences").
		WithArgs(int64(7), "", sqlmock.AnyArg(), sqlmock.AnyArg(), until, sqlmock.AnyArg(), sqlmock.AnyArg()).
		WillReturnRows(sqlmock.NewRows([]string{
			"id", "rule_id", "platform", "group_id", "region", "until", "reason", "created_by", "created_at",
		}).AddRow(int64(11), int64(7), "", nil, nil, until, "rule scoped", nil, createdAt))

	created, err := repo.CreateAlertSilence(context.Background(), &service.OpsAlertSilence{
		RuleID:   7,
		Platform: "   ",
		Until:    until,
		Reason:   "rule scoped",
	})

	require.NoError(t, err)
	require.Equal(t, int64(11), created.ID)
	require.Empty(t, created.Platform)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestIsAlertSilenced_QueriesEmptyPlatform(t *testing.T) {
	repo, mock := newOpsAlertSilenceRepoMock(t)
	now := time.Date(2026, time.July, 15, 12, 0, 0, 0, time.UTC)

	mock.ExpectQuery("SELECT 1\\s+FROM ops_alert_silences").
		WithArgs(int64(7), "", sqlmock.AnyArg(), sqlmock.AnyArg(), now).
		WillReturnRows(sqlmock.NewRows([]string{"exists"}).AddRow(1))

	silenced, err := repo.IsAlertSilenced(context.Background(), 7, "   ", nil, nil, now)

	require.NoError(t, err)
	require.True(t, silenced)
	require.NoError(t, mock.ExpectationsWereMet())
}
