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
		Enabled:                   true,
		RolloutPercent:            10,
		HealthTTFTMs:              8000,
		CircuitMinSamples:         3,
		CircuitFailureRatePercent: 50,
		CircuitCooldownSeconds:    300,
	}
	for range 3 {
		stats.reportStreamHealth(1, "gpt-5.5", nil, "first_output_timeout", policy)
	}
	snapshot := stats.streamHealthSnapshot(1, "gpt-5.5")
	require.True(t, snapshot.CircuitOpen)

	primary, retry := splitOpenAIStreamCircuitCandidates([]openAIAccountCandidateScore{
		{account: &Account{ID: 1}, streamHealth: snapshot},
		{account: &Account{ID: 2}},
	})
	require.Len(t, primary, 1)
	require.Len(t, retry, 1)
	require.Equal(t, int64(2), primary[0].account.ID)
	require.Equal(t, int64(1), retry[0].account.ID)
}

func TestOpenAIStreamHealthRoutingProtectsWholePoolBeforeBudgetRollout(t *testing.T) {
	stats := newOpenAIAccountRuntimeStats()
	policy := config.GatewayOpenAIStreamGovernanceConfig{
		Enabled:                   true,
		RolloutPercent:            10,
		HealthTTFTMs:              8000,
		CircuitMinSamples:         3,
		CircuitFailureRatePercent: 50,
		CircuitCooldownSeconds:    300,
	}
	for range 3 {
		stats.reportStreamHealth(14, "gpt-5.5", nil, "first_output_timeout", policy)
	}

	cfg := &config.Config{}
	cfg.Gateway.OpenAIStreamGovernance = policy
	cfg.Gateway.OpenAIWS.LBTopK = 7
	scheduler := &defaultOpenAIAccountScheduler{
		service: &OpenAIGatewayService{cfg: cfg},
		stats:   stats,
	}
	plan := scheduler.buildOpenAIAccountLoadPlan(context.Background(), OpenAIAccountScheduleRequest{RequestedModel: "gpt-5.5"}, []*Account{
		{ID: 14, Platform: PlatformOpenAI, Type: AccountTypeOAuth},
		{ID: 23, Platform: PlatformOpenAI, Type: AccountTypeOAuth},
	}, map[int64]*AccountLoadInfo{})

	require.Equal(t, []int64{23}, openAIPlanAccountIDs(plan.candidates))
	require.Equal(t, []int64{14}, openAIPlanAccountIDs(plan.slowTTFTRetry))
	require.Equal(t, 1, plan.candidateCount)
}

func TestOpenAIStreamHealthIsolatedByModelAndUsesP95(t *testing.T) {
	stats := newOpenAIAccountRuntimeStats()
	policy := config.GatewayOpenAIStreamGovernanceConfig{
		Enabled:                   true,
		RolloutPercent:            10,
		HealthTTFTMs:              8000,
		CircuitMinSamples:         3,
		CircuitFailureRatePercent: 50,
		CircuitCooldownSeconds:    300,
	}
	for _, ttft := range []int{1000, 1000, 9000} {
		ttft := ttft
		stats.reportStreamHealth(18, "gpt-5.5", &ttft, "succeeded", policy)
	}
	for _, ttft := range []int{1000, 1000, 1000} {
		ttft := ttft
		stats.reportStreamHealth(18, "gpt-5.6-sol", &ttft, "succeeded", policy)
	}

	gpt55 := stats.streamHealthSnapshot(18, "gpt-5.5")
	gpt56 := stats.streamHealthSnapshot(18, "gpt-5.6-sol")
	require.Equal(t, 9000, gpt55.TTFTP95_5mMs)
	require.True(t, gpt55.CircuitOpen, "P95 must open the circuit even when the mean is below the threshold")
	require.False(t, gpt56.CircuitOpen, "slow gpt-5.5 samples must not evict a fast gpt-5.6-sol route")

	cfg := &config.Config{}
	cfg.Gateway.OpenAIStreamGovernance = policy
	scheduler := &defaultOpenAIAccountScheduler{
		service: &OpenAIGatewayService{cfg: cfg},
		stats:   stats,
	}
	accounts := []*Account{
		{ID: 18, Platform: PlatformOpenAI, Type: AccountTypeOAuth},
		{ID: 23, Platform: PlatformOpenAI, Type: AccountTypeOAuth},
	}
	slowPlan := scheduler.buildOpenAIAccountLoadPlan(context.Background(), OpenAIAccountScheduleRequest{RequestedModel: "gpt-5.5"}, accounts, map[int64]*AccountLoadInfo{})
	fastPlan := scheduler.buildOpenAIAccountLoadPlan(context.Background(), OpenAIAccountScheduleRequest{RequestedModel: "gpt-5.6-sol"}, accounts, map[int64]*AccountLoadInfo{})
	require.Equal(t, []int64{23}, openAIPlanAccountIDs(slowPlan.candidates))
	require.Equal(t, []int64{18}, openAIPlanAccountIDs(slowPlan.slowTTFTRetry))
	require.ElementsMatch(t, []int64{18, 23}, openAIPlanAccountIDs(fastPlan.candidates))
	require.Empty(t, fastPlan.slowTTFTRetry)
}
