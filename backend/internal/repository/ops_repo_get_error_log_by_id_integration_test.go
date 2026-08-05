//go:build integration

package repository

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func opsStatusCodePtr(v int) *int { return &v }

func TestGetErrorLogByID_APIKeyPrefixAndUpstreamStatus(t *testing.T) {
	ctx := context.Background()
	_, _ = integrationDB.ExecContext(ctx, "TRUNCATE ops_error_logs RESTART IDENTITY CASCADE")
	repo := NewOpsRepository(integrationDB).(*opsRepository)

	var plainID int64
	err := integrationDB.QueryRowContext(ctx, `
		INSERT INTO ops_error_logs (
			error_phase, error_type, severity, status_code, created_at
		) VALUES (
			'upstream', 'upstream_error', 'error', 500, NOW()
		) RETURNING id`,
	).Scan(&plainID)
	require.NoError(t, err)

	plain, err := repo.GetErrorLogByID(ctx, plainID)
	require.NoError(t, err)
	require.Empty(t, plain.APIKeyPrefix)

	validID, err := repo.InsertErrorLog(ctx, &service.OpsInsertErrorLogInput{
		ErrorPhase:   "request",
		ErrorType:    "api_error",
		Severity:     "error",
		StatusCode:   402,
		CreatedAt:    time.Now(),
		APIKeyPrefix: "sk-valid",
	})
	require.NoError(t, err)

	valid, err := repo.GetErrorLogByID(ctx, validID)
	require.NoError(t, err)
	require.Equal(t, "sk-valid", valid.APIKeyPrefix)

	zero := 0
	credentialFailureID, err := repo.InsertErrorLog(ctx, &service.OpsInsertErrorLogInput{
		ErrorPhase:         "account_auth",
		ErrorType:          "upstream_error",
		Severity:           "error",
		StatusCode:         503,
		UpstreamStatusCode: &zero,
		CreatedAt:          time.Now(),
	})
	require.NoError(t, err)

	credentialFailure, err := repo.GetErrorLogByID(ctx, credentialFailureID)
	require.NoError(t, err)
	require.NotNil(t, credentialFailure.UpstreamStatusCode)
	require.Zero(t, *credentialFailure.UpstreamStatusCode)

	postHeartbeatID, err := repo.InsertErrorLog(ctx, &service.OpsInsertErrorLogInput{
		ErrorPhase:         "upstream",
		ErrorType:          "upstream_error",
		Severity:           "error",
		StatusCode:         200,
		UpstreamStatusCode: opsStatusCodePtr(504),
		CreatedAt:          time.Now(),
	})
	require.NoError(t, err)

	list, err := repo.ListErrorLogs(ctx, &service.OpsErrorLogFilter{
		Page: 1, PageSize: 50, Phase: "upstream", IncludeRecoveredUpstream: true, View: "all",
	})
	require.NoError(t, err)
	var listed *service.OpsErrorLog
	for _, item := range list.Errors {
		if item.ID == postHeartbeatID {
			listed = item
			break
		}
	}
	require.NotNil(t, listed)
	require.NotNil(t, listed.StatusCode)
	require.NotNil(t, listed.UpstreamStatusCode)
	require.Equal(t, 200, *listed.StatusCode)
	require.Equal(t, 504, *listed.UpstreamStatusCode)

	detail, err := repo.GetErrorLogByID(ctx, postHeartbeatID)
	require.NoError(t, err)
	require.NotNil(t, detail.StatusCode)
	require.NotNil(t, detail.UpstreamStatusCode)
	require.Equal(t, 200, *detail.StatusCode)
	require.Equal(t, 504, *detail.UpstreamStatusCode)
	encoded, err := json.Marshal(detail)
	require.NoError(t, err)
	var payload map[string]any
	require.NoError(t, json.Unmarshal(encoded, &payload))
	require.Equal(t, float64(200), payload["status_code"])
	require.Equal(t, float64(504), payload["upstream_status_code"])
}
