package service

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/pkg/ctxkey"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestOpenAIStreamGovernanceReservesSecondAttemptBudget(t *testing.T) {
	now := time.Now()
	plan := &openAIStreamGovernancePlan{
		enabled:             true,
		totalDeadline:       now.Add(10 * time.Second),
		firstAttemptBudget:  6 * time.Second,
		backupAttemptBudget: 4 * time.Second,
	}

	first := plan.claimAttemptTimeout(now)
	second := plan.claimAttemptTimeout(now)
	require.Equal(t, 6*time.Second, first)
	require.Equal(t, 4*time.Second, second)
}

func TestOpenAIStreamGovernanceBudgetIncludesHeaderWaitFromRequestStart(t *testing.T) {
	startedAt := time.Now()
	plan := &openAIStreamGovernancePlan{
		enabled:             true,
		totalDeadline:       startedAt.Add(10 * time.Second),
		firstAttemptBudget:  6 * time.Second,
		backupAttemptBudget: 4 * time.Second,
	}

	// Request parsing and account selection already used two seconds. The first
	// upstream header wait must therefore end at request-start + six seconds,
	// rather than granting six new seconds after selection.
	first, firstDeadline := plan.claimAttempt(startedAt.Add(2 * time.Second))
	require.Equal(t, 4*time.Second, first)
	require.Equal(t, startedAt.Add(6*time.Second), firstDeadline)

	second, secondDeadline := plan.claimAttempt(startedAt.Add(6 * time.Second))
	require.Equal(t, 4*time.Second, second)
	require.Equal(t, startedAt.Add(10*time.Second), secondDeadline)
}

func TestOpenAIStreamGovernanceRolloutIsRequestIDDeterministic(t *testing.T) {
	ctx := context.WithValue(context.Background(), ctxkey.RequestID, "stream-governance-request")
	first := openAIStreamGovernanceInRollout(ctx, 10)
	for range 20 {
		require.Equal(t, first, openAIStreamGovernanceInRollout(ctx, 10))
	}
	require.False(t, openAIStreamGovernanceInRollout(context.Background(), 10))
}

func TestWithOpenAIStreamGovernancePlanUsesTotalBudgetWhenReplayIsUnsafe(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", nil)
	svc := &OpenAIGatewayService{cfg: &config.Config{Gateway: config.GatewayConfig{
		OpenAIStreamGovernance: config.GatewayOpenAIStreamGovernanceConfig{
			Enabled:                   true,
			RolloutPercent:            100,
			TotalBudgetSeconds:        10,
			FirstAttemptBudgetSeconds: 6,
		},
	}}}
	startedAt := time.Now()

	ctx := svc.WithOpenAIStreamGovernancePlan(c, startedAt, false)
	plan := openAIStreamGovernancePlanFromContext(ctx)
	require.NotNil(t, plan)
	first, deadline := plan.claimAttempt(startedAt)
	require.Equal(t, 10*time.Second, first)
	require.Equal(t, startedAt.Add(10*time.Second), deadline)
}

func TestWithOpenAIStreamGovernancePlanReservesBackupForSafeReplay(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", nil)
	svc := &OpenAIGatewayService{cfg: &config.Config{Gateway: config.GatewayConfig{
		OpenAIStreamGovernance: config.GatewayOpenAIStreamGovernanceConfig{
			Enabled:                   true,
			RolloutPercent:            100,
			TotalBudgetSeconds:        10,
			FirstAttemptBudgetSeconds: 6,
		},
	}}}
	startedAt := time.Now()

	ctx := svc.WithOpenAIStreamGovernancePlan(c, startedAt, true)
	plan := openAIStreamGovernancePlanFromContext(ctx)
	require.NotNil(t, plan)
	first, firstDeadline := plan.claimAttempt(startedAt)
	second, secondDeadline := plan.claimAttempt(startedAt.Add(6 * time.Second))
	require.Equal(t, 6*time.Second, first)
	require.Equal(t, startedAt.Add(6*time.Second), firstDeadline)
	require.Equal(t, 4*time.Second, second)
	require.Equal(t, startedAt.Add(10*time.Second), secondDeadline)
}

func TestOpenAIStreamHealthCircuitMovesAccountBehindHealthyCandidates(t *testing.T) {
	stats := newOpenAIAccountRuntimeStats()
	policy := config.GatewayOpenAIStreamGovernanceConfig{
		HealthTTFTMs:              8000,
		CircuitMinSamples:         3,
		CircuitFailureRatePercent: 50,
		CircuitCooldownSeconds:    300,
	}
	for range 3 {
		stats.reportStreamHealth(1, nil, "first_output_timeout", policy)
	}
	snapshot := stats.streamHealthSnapshot(1)
	require.True(t, snapshot.CircuitOpen)

	primary, retry := splitOpenAIStreamCircuitCandidates([]openAIAccountCandidateScore{
		{account: &Account{ID: 1}, streamHealth: snapshot},
		{account: &Account{ID: 2}},
		{account: &Account{ID: 3}},
	})
	require.Len(t, primary, 2)
	require.Len(t, retry, 1)
	require.Equal(t, int64(1), retry[0].account.ID)
}
