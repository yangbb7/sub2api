//go:build unit

package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

var _ OpsRepository = (*stubOpsRepo)(nil)

type stubOpsRepo struct {
	OpsRepository
	overview *OpsDashboardOverview
	err      error
}

type rateAlertOpsRepoStub struct {
	OpsRepository
	rules       []*OpsAlertRule
	overview    *OpsDashboardOverview
	activeEvent *OpsAlertEvent
	created     *OpsAlertEvent
	resolvedID  int64
	status      string
}

func (s *rateAlertOpsRepoStub) ListAlertRules(context.Context) ([]*OpsAlertRule, error) {
	return s.rules, nil
}

func (s *rateAlertOpsRepoStub) GetLatestSystemMetrics(context.Context, int) (*OpsSystemMetricsSnapshot, error) {
	return nil, nil
}

func (s *rateAlertOpsRepoStub) GetDashboardOverview(context.Context, *OpsDashboardFilter) (*OpsDashboardOverview, error) {
	return s.overview, nil
}

func (s *rateAlertOpsRepoStub) GetActiveAlertEvent(context.Context, int64) (*OpsAlertEvent, error) {
	return s.activeEvent, nil
}

func (s *rateAlertOpsRepoStub) GetLatestAlertEvent(context.Context, int64) (*OpsAlertEvent, error) {
	return nil, nil
}

func (s *rateAlertOpsRepoStub) CreateAlertEvent(_ context.Context, event *OpsAlertEvent) (*OpsAlertEvent, error) {
	s.created = event
	return event, nil
}

func (s *rateAlertOpsRepoStub) UpdateAlertEventStatus(_ context.Context, eventID int64, status string, _ *time.Time) error {
	s.resolvedID = eventID
	s.status = status
	return nil
}

func (s *rateAlertOpsRepoStub) UpsertJobHeartbeat(context.Context, *OpsUpsertJobHeartbeatInput) error {
	return nil
}

type alertUserRepoStub struct {
	UserRepository
	user *User
	err  error
}

func (s *alertUserRepoStub) GetByID(_ context.Context, _ int64) (*User, error) {
	return s.user, s.err
}

type alertConcurrencyCacheStub struct {
	ConcurrencyCache
	loads map[int64]*UserLoadInfo
	err   error
}

type silencedUserAlertOpsRepoStub struct {
	OpsRepository
	rules             []*OpsAlertRule
	silenced          bool
	silenceCalled     bool
	silencePlatform   string
	silenceGroupID    *int64
	silenceUserID     *int64
	silenceRegion     *string
	activeEvent       *OpsAlertEvent
	createdEventCount int
	resolvedEventID   int64
	resolvedStatus    string
}

func (s *alertConcurrencyCacheStub) GetUsersLoadBatch(_ context.Context, _ []UserWithConcurrency) (map[int64]*UserLoadInfo, error) {
	return s.loads, s.err
}

func (s *silencedUserAlertOpsRepoStub) ListAlertRules(context.Context) ([]*OpsAlertRule, error) {
	return s.rules, nil
}

func (s *silencedUserAlertOpsRepoStub) GetLatestSystemMetrics(context.Context, int) (*OpsSystemMetricsSnapshot, error) {
	return nil, nil
}

func (s *silencedUserAlertOpsRepoStub) GetActiveAlertEvent(context.Context, int64) (*OpsAlertEvent, error) {
	return s.activeEvent, nil
}

func (s *silencedUserAlertOpsRepoStub) IsAlertSilenced(_ context.Context, _ int64, platform string, groupID *int64, userID *int64, region *string, _ time.Time) (bool, error) {
	s.silenceCalled = true
	s.silencePlatform = platform
	s.silenceGroupID = groupID
	s.silenceUserID = userID
	s.silenceRegion = region
	return s.silenced, nil
}

func (s *silencedUserAlertOpsRepoStub) GetLatestAlertEvent(context.Context, int64) (*OpsAlertEvent, error) {
	return nil, nil
}

func (s *silencedUserAlertOpsRepoStub) CreateAlertEvent(_ context.Context, event *OpsAlertEvent) (*OpsAlertEvent, error) {
	s.createdEventCount++
	return event, nil
}

func (s *silencedUserAlertOpsRepoStub) UpdateAlertEventStatus(_ context.Context, eventID int64, status string, _ *time.Time) error {
	s.resolvedEventID = eventID
	s.resolvedStatus = status
	return nil
}

func (s *silencedUserAlertOpsRepoStub) UpsertJobHeartbeat(context.Context, *OpsUpsertJobHeartbeatInput) error {
	return nil
}

func (s *stubOpsRepo) GetDashboardOverview(ctx context.Context, filter *OpsDashboardFilter) (*OpsDashboardOverview, error) {
	if s.err != nil {
		return nil, s.err
	}
	if s.overview != nil {
		return s.overview, nil
	}
	return &OpsDashboardOverview{}, nil
}

func TestOpsAlertRateSampleMinimum(t *testing.T) {
	t.Parallel()
	rule := &OpsAlertRule{MetricType: "error_rate", Filters: map[string]any{
		"min_sla_requests": float64(30),
		"min_sla_errors":   "10",
	}}
	require.Equal(t, int64(30), parseOpsAlertMinimumSLARequests(rule.Filters))
	require.Equal(t, int64(10), parseOpsAlertMinimumSLAErrors(rule.Filters))
	require.False(t, meetsOpsAlertMinimumSample(rule, opsAlertRateMetricSample{SLARequestCount: 30, SLAErrorCount: 9}))
	require.False(t, meetsOpsAlertMinimumSample(rule, opsAlertRateMetricSample{SLARequestCount: 29, SLAErrorCount: 10}))
	require.True(t, meetsOpsAlertMinimumSample(rule, opsAlertRateMetricSample{SLARequestCount: 30, SLAErrorCount: 10}))
}

func TestOpsAlertEvaluatorRateRuleRequiresActionableSample(t *testing.T) {
	t.Parallel()
	rule := &OpsAlertRule{
		ID:               10,
		Name:             "high error rate",
		Enabled:          true,
		Severity:         "P0",
		MetricType:       "error_rate",
		Operator:         ">",
		Threshold:        25,
		WindowMinutes:    15,
		SustainedMinutes: 1,
		Filters: map[string]any{
			"min_sla_requests": float64(30),
			"min_sla_errors":   float64(10),
		},
	}

	t.Run("insufficient sample resolves an existing event", func(t *testing.T) {
		repo := &rateAlertOpsRepoStub{
			rules: []*OpsAlertRule{rule},
			overview: &OpsDashboardOverview{
				RequestCountSLA: 3,
				ErrorCountSLA:   1,
				ErrorRate:       1.0 / 3.0,
			},
			activeEvent: &OpsAlertEvent{ID: 99, RuleID: rule.ID, Status: OpsAlertStatusFiring},
		}
		NewOpsAlertEvaluatorService(nil, repo, nil, nil, nil, nil).evaluateOnce(time.Minute)
		require.Nil(t, repo.created)
		require.Equal(t, int64(99), repo.resolvedID)
		require.Equal(t, OpsAlertStatusResolved, repo.status)
	})

	t.Run("no traffic resolves an existing event", func(t *testing.T) {
		repo := &rateAlertOpsRepoStub{
			rules: []*OpsAlertRule{rule},
			overview: &OpsDashboardOverview{
				RequestCountSLA: 0,
			},
			activeEvent: &OpsAlertEvent{ID: 100, RuleID: rule.ID, Status: OpsAlertStatusFiring},
		}
		NewOpsAlertEvaluatorService(nil, repo, nil, nil, nil, nil).evaluateOnce(time.Minute)
		require.Nil(t, repo.created)
		require.Equal(t, int64(100), repo.resolvedID)
		require.Equal(t, OpsAlertStatusResolved, repo.status)
	})

	t.Run("actionable sustained error captures denominator", func(t *testing.T) {
		repo := &rateAlertOpsRepoStub{
			rules: []*OpsAlertRule{rule},
			overview: &OpsDashboardOverview{
				RequestCountSLA:              60,
				ErrorCountSLA:                20,
				UpstreamErrorCountExcl429529: 18,
				ErrorRate:                    1.0 / 3.0,
			},
		}
		NewOpsAlertEvaluatorService(nil, repo, nil, nil, nil, nil).evaluateOnce(time.Minute)
		require.NotNil(t, repo.created)
		require.Contains(t, repo.created.Description, "SLA requests=60")
		require.Contains(t, repo.created.Description, "SLA errors=20")
		require.Equal(t, int64(60), repo.created.Dimensions["sla_request_count"])
		require.Equal(t, int64(20), repo.created.Dimensions["sla_error_count"])
	})
}

func TestComputeGroupAvailableRatio(t *testing.T) {
	t.Parallel()

	t.Run("正常情况: 10个账号, 8个可用 = 80%", func(t *testing.T) {
		t.Parallel()

		got := computeGroupAvailableRatio(&GroupAvailability{
			TotalAccounts:  10,
			AvailableCount: 8,
		})
		require.InDelta(t, 80.0, got, 0.0001)
	})

	t.Run("边界情况: TotalAccounts = 0 应返回 0", func(t *testing.T) {
		t.Parallel()

		got := computeGroupAvailableRatio(&GroupAvailability{
			TotalAccounts:  0,
			AvailableCount: 8,
		})
		require.Equal(t, 0.0, got)
	})

	t.Run("边界情况: AvailableCount = 0 应返回 0%", func(t *testing.T) {
		t.Parallel()

		got := computeGroupAvailableRatio(&GroupAvailability{
			TotalAccounts:  10,
			AvailableCount: 0,
		})
		require.Equal(t, 0.0, got)
	})
}

func TestUserConcurrencyUtilizationPercent(t *testing.T) {
	t.Parallel()

	got, ok := userConcurrencyUtilizationPercent(&UserConcurrencyInfo{UserID: 2, CurrentInUse: 8, MaxCapacity: 10})
	require.True(t, ok)
	require.InDelta(t, 80.0, got, 0.0001)

	got, ok = userConcurrencyUtilizationPercent(&UserConcurrencyInfo{UserID: 2, MaxCapacity: 10})
	require.True(t, ok)
	require.Equal(t, 0.0, got)

	_, ok = userConcurrencyUtilizationPercent(nil)
	require.False(t, ok)
}

func TestComputeUserConcurrencyUtilizationPercent(t *testing.T) {
	user := &User{ID: 2, Email: "user@example.com", Concurrency: 10, Status: StatusActive}
	newEvaluator := func(cache *alertConcurrencyCacheStub) *OpsAlertEvaluatorService {
		return &OpsAlertEvaluatorService{opsService: &OpsService{
			userRepo:           &alertUserRepoStub{user: user},
			concurrencyService: NewConcurrencyService(cache),
		}}
	}
	rule := &OpsAlertRule{
		MetricType: "user_concurrency_utilization_percent",
		Filters:    map[string]any{"user_id": float64(2)},
	}

	t.Run("8 of 10", func(t *testing.T) {
		evaluator := newEvaluator(&alertConcurrencyCacheStub{loads: map[int64]*UserLoadInfo{
			2: {UserID: 2, CurrentConcurrency: 8},
		}})
		got, ok, inactive := evaluator.computeUserConcurrencyRuleMetric(context.Background(), rule)
		require.True(t, ok)
		require.False(t, inactive)
		require.InDelta(t, 80.0, got, 0.0001)
	})

	t.Run("idle is zero", func(t *testing.T) {
		evaluator := newEvaluator(&alertConcurrencyCacheStub{loads: map[int64]*UserLoadInfo{
			2: {UserID: 2, CurrentConcurrency: 0},
		}})
		got, ok, inactive := evaluator.computeUserConcurrencyRuleMetric(context.Background(), rule)
		require.True(t, ok)
		require.False(t, inactive)
		require.Equal(t, 0.0, got)
	})

	t.Run("redis failure is not evaluated", func(t *testing.T) {
		evaluator := newEvaluator(&alertConcurrencyCacheStub{err: errors.New("redis unavailable")})
		_, ok, inactive := evaluator.computeUserConcurrencyRuleMetric(context.Background(), rule)
		require.False(t, ok)
		require.False(t, inactive)
	})

	t.Run("missing load is not evaluated", func(t *testing.T) {
		evaluator := newEvaluator(&alertConcurrencyCacheStub{loads: map[int64]*UserLoadInfo{}})
		_, ok, inactive := evaluator.computeUserConcurrencyRuleMetric(context.Background(), rule)
		require.False(t, ok)
		require.False(t, inactive)
	})

	t.Run("deleted user is inactive", func(t *testing.T) {
		evaluator := &OpsAlertEvaluatorService{opsService: &OpsService{
			userRepo: &alertUserRepoStub{err: ErrUserNotFound},
			concurrencyService: NewConcurrencyService(&alertConcurrencyCacheStub{
				loads: map[int64]*UserLoadInfo{},
			}),
		}}
		got, ok, inactive := evaluator.computeUserConcurrencyRuleMetric(context.Background(), rule)
		require.True(t, ok)
		require.True(t, inactive)
		require.Equal(t, 0.0, got)
	})

	t.Run("unlimited user is inactive", func(t *testing.T) {
		evaluator := &OpsAlertEvaluatorService{opsService: &OpsService{
			userRepo: &alertUserRepoStub{user: &User{ID: 2, Concurrency: 0, Status: StatusActive}},
			concurrencyService: NewConcurrencyService(&alertConcurrencyCacheStub{
				loads: map[int64]*UserLoadInfo{},
			}),
		}}
		got, ok, inactive := evaluator.computeUserConcurrencyRuleMetric(context.Background(), rule)
		require.True(t, ok)
		require.True(t, inactive)
		require.Equal(t, 0.0, got)
	})

	t.Run("database failure is not evaluated", func(t *testing.T) {
		evaluator := &OpsAlertEvaluatorService{opsService: &OpsService{
			userRepo: &alertUserRepoStub{err: errors.New("database unavailable")},
			concurrencyService: NewConcurrencyService(&alertConcurrencyCacheStub{
				loads: map[int64]*UserLoadInfo{},
			}),
		}}
		_, ok, inactive := evaluator.computeUserConcurrencyRuleMetric(context.Background(), rule)
		require.False(t, ok)
		require.False(t, inactive)
	})
}

func TestValidateUserConcurrencyAlertTarget(t *testing.T) {
	t.Run("active limited user", func(t *testing.T) {
		ops := &OpsService{userRepo: &alertUserRepoStub{user: &User{
			ID: 2, Concurrency: 10, Status: StatusActive,
		}}}
		require.NoError(t, ops.ValidateUserConcurrencyAlertTarget(context.Background(), 2))
	})

	t.Run("unlimited user rejected", func(t *testing.T) {
		ops := &OpsService{userRepo: &alertUserRepoStub{user: &User{
			ID: 2, Concurrency: 0, Status: StatusActive,
		}}}
		require.Error(t, ops.ValidateUserConcurrencyAlertTarget(context.Background(), 2))
	})

	t.Run("repository failure propagated", func(t *testing.T) {
		wantErr := errors.New("database unavailable")
		ops := &OpsService{userRepo: &alertUserRepoStub{err: wantErr}}
		require.ErrorIs(t, ops.ValidateUserConcurrencyAlertTarget(context.Background(), 2), wantErr)
	})
}

func TestUserConcurrencyAlertDimensions(t *testing.T) {
	userID := int64(2)
	dims := buildOpsAlertDimensions("", nil, &userID)
	require.Equal(t, map[string]any{"user_id": int64(2)}, dims)

	description := buildOpsAlertDescription(&OpsAlertRule{
		MetricType: "user_concurrency_utilization_percent",
		Operator:   ">=",
		Threshold:  80,
	}, 90, 1, "", nil, &userID)
	require.Contains(t, description, "user_id=2")
}

func TestOpsAlertEvaluator_UserConcurrencyRuleScopedSilence(t *testing.T) {
	repo := &silencedUserAlertOpsRepoStub{silenced: true, rules: []*OpsAlertRule{{
		ID:               7,
		Name:             "user concurrency",
		Enabled:          true,
		Severity:         "P1",
		MetricType:       "user_concurrency_utilization_percent",
		Operator:         ">=",
		Threshold:        80,
		WindowMinutes:    1,
		SustainedMinutes: 1,
		Filters:          map[string]any{"user_id": float64(2)},
	}}}
	ops := &OpsService{
		opsRepo: repo,
		userRepo: &alertUserRepoStub{user: &User{
			ID: 2, Concurrency: 10, Status: StatusActive,
		}},
		concurrencyService: NewConcurrencyService(&alertConcurrencyCacheStub{loads: map[int64]*UserLoadInfo{
			2: {UserID: 2, CurrentConcurrency: 8},
		}}),
	}
	evaluator := NewOpsAlertEvaluatorService(ops, repo, nil, nil, nil, nil)

	evaluator.evaluateOnce(time.Minute)

	require.True(t, repo.silenceCalled)
	require.Empty(t, repo.silencePlatform)
	require.Nil(t, repo.silenceGroupID)
	require.NotNil(t, repo.silenceUserID)
	require.Equal(t, int64(2), *repo.silenceUserID)
	require.Nil(t, repo.silenceRegion)
	require.Zero(t, repo.createdEventCount)
}

func TestOpsAlertEvaluator_InactiveUserTargetDoesNotFire(t *testing.T) {
	newRepo := func(activeEvent *OpsAlertEvent) *silencedUserAlertOpsRepoStub {
		return &silencedUserAlertOpsRepoStub{
			activeEvent: activeEvent,
			rules: []*OpsAlertRule{{
				ID:               7,
				Name:             "inactive user concurrency",
				Enabled:          true,
				Severity:         "P1",
				MetricType:       "user_concurrency_utilization_percent",
				Operator:         "<",
				Threshold:        10,
				WindowMinutes:    1,
				SustainedMinutes: 1,
				Filters:          map[string]any{"user_id": float64(2)},
			}},
		}
	}
	newEvaluator := func(repo *silencedUserAlertOpsRepoStub) *OpsAlertEvaluatorService {
		ops := &OpsService{
			opsRepo:  repo,
			userRepo: &alertUserRepoStub{err: ErrUserNotFound},
			concurrencyService: NewConcurrencyService(&alertConcurrencyCacheStub{
				loads: map[int64]*UserLoadInfo{},
			}),
		}
		return NewOpsAlertEvaluatorService(ops, repo, nil, nil, nil, nil)
	}

	t.Run("does not create a low utilization alert", func(t *testing.T) {
		repo := newRepo(nil)
		newEvaluator(repo).evaluateOnce(time.Minute)

		require.Zero(t, repo.createdEventCount)
		require.False(t, repo.silenceCalled)
	})

	t.Run("resolves an existing alert", func(t *testing.T) {
		repo := newRepo(&OpsAlertEvent{ID: 99, RuleID: 7, Status: OpsAlertStatusFiring})
		newEvaluator(repo).evaluateOnce(time.Minute)

		require.Zero(t, repo.createdEventCount)
		require.Equal(t, int64(99), repo.resolvedEventID)
		require.Equal(t, OpsAlertStatusResolved, repo.resolvedStatus)
	})
}

func TestCountAccountsByCondition(t *testing.T) {
	t.Parallel()

	t.Run("测试限流账号统计: acc.IsRateLimited", func(t *testing.T) {
		t.Parallel()

		accounts := map[int64]*AccountAvailability{
			1: {IsRateLimited: true},
			2: {IsRateLimited: false},
			3: {IsRateLimited: true},
		}

		got := countAccountsByCondition(accounts, func(acc *AccountAvailability) bool {
			return acc.IsRateLimited
		})
		require.Equal(t, int64(2), got)
	})

	t.Run("测试错误账号统计（排除临时不可调度）: acc.HasError && acc.TempUnschedulableUntil == nil", func(t *testing.T) {
		t.Parallel()

		until := time.Now().UTC().Add(5 * time.Minute)
		accounts := map[int64]*AccountAvailability{
			1: {HasError: true},
			2: {HasError: true, TempUnschedulableUntil: &until},
			3: {HasError: false},
		}

		got := countAccountsByCondition(accounts, func(acc *AccountAvailability) bool {
			return acc.HasError && acc.TempUnschedulableUntil == nil
		})
		require.Equal(t, int64(1), got)
	})

	t.Run("边界情况: 空 map 应返回 0", func(t *testing.T) {
		t.Parallel()

		got := countAccountsByCondition(map[int64]*AccountAvailability{}, func(acc *AccountAvailability) bool {
			return acc.IsRateLimited
		})
		require.Equal(t, int64(0), got)
	})
}

// TestComputeRuleMetric_AccountTempUnscheduledCount verifies the new
// account_temp_unscheduled_count metric counts accounts currently in the
// temp-unscheduled window and ignores those whose window has expired or
// were never temp-unscheduled.
func TestComputeRuleMetric_AccountTempUnscheduledCount(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	futureUntil := now.Add(5 * time.Minute)
	pastUntil := now.Add(-1 * time.Minute)

	availability := &OpsAccountAvailability{
		Accounts: map[int64]*AccountAvailability{
			// currently temp-unscheduled (window active)
			1: {TempUnschedulableUntil: &futureUntil},
			2: {TempUnschedulableUntil: &futureUntil},
			// temp-unsched window already expired → should NOT count
			3: {TempUnschedulableUntil: &pastUntil},
			// never temp-unscheduled
			4: {HasError: true},
			5: {IsRateLimited: true},
		},
	}

	opsService := &OpsService{
		getAccountAvailability: func(_ context.Context, _ string, _ *int64) (*OpsAccountAvailability, error) {
			return availability, nil
		},
	}
	svc := &OpsAlertEvaluatorService{
		opsService: opsService,
		opsRepo:    &stubOpsRepo{},
	}

	rule := &OpsAlertRule{MetricType: "account_temp_unscheduled_count"}
	val, ok := svc.computeRuleMetric(context.Background(), rule, nil,
		now.Add(-5*time.Minute), now, "", nil)

	require.True(t, ok)
	require.InDelta(t, 2.0, val, 0.0001, "only 2 accounts have an active temp-unsched window")
}

func TestComputeRuleMetricNewIndicators(t *testing.T) {
	t.Parallel()

	groupID := int64(101)
	platform := "openai"

	availability := &OpsAccountAvailability{
		Group: &GroupAvailability{
			GroupID:        groupID,
			TotalAccounts:  10,
			AvailableCount: 8,
		},
		Accounts: map[int64]*AccountAvailability{
			1: {IsRateLimited: true},
			2: {IsRateLimited: true},
			3: {HasError: true},
			4: {HasError: true, TempUnschedulableUntil: timePtr(time.Now().UTC().Add(2 * time.Minute))},
			5: {HasError: false, IsRateLimited: false},
		},
	}

	opsService := &OpsService{
		getAccountAvailability: func(_ context.Context, _ string, _ *int64) (*OpsAccountAvailability, error) {
			return availability, nil
		},
	}

	svc := &OpsAlertEvaluatorService{
		opsService: opsService,
		opsRepo:    &stubOpsRepo{overview: &OpsDashboardOverview{}},
	}

	start := time.Now().UTC().Add(-5 * time.Minute)
	end := time.Now().UTC()
	ctx := context.Background()

	tests := []struct {
		name       string
		metricType string
		groupID    *int64
		wantValue  float64
		wantOK     bool
	}{
		{
			name:       "group_available_accounts",
			metricType: "group_available_accounts",
			groupID:    &groupID,
			wantValue:  8,
			wantOK:     true,
		},
		{
			name:       "group_available_ratio",
			metricType: "group_available_ratio",
			groupID:    &groupID,
			wantValue:  80.0,
			wantOK:     true,
		},
		{
			name:       "account_rate_limited_count",
			metricType: "account_rate_limited_count",
			groupID:    nil,
			wantValue:  2,
			wantOK:     true,
		},
		{
			name:       "account_error_count",
			metricType: "account_error_count",
			groupID:    nil,
			wantValue:  1,
			wantOK:     true,
		},
		{
			name:       "group_available_accounts without group_id returns false",
			metricType: "group_available_accounts",
			groupID:    nil,
			wantValue:  0,
			wantOK:     false,
		},
		{
			name:       "group_available_ratio without group_id returns false",
			metricType: "group_available_ratio",
			groupID:    nil,
			wantValue:  0,
			wantOK:     false,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			rule := &OpsAlertRule{
				MetricType: tt.metricType,
			}
			gotValue, gotOK := svc.computeRuleMetric(ctx, rule, nil, start, end, platform, tt.groupID)
			require.Equal(t, tt.wantOK, gotOK)
			if !tt.wantOK {
				return
			}
			require.InDelta(t, tt.wantValue, gotValue, 0.0001)
		})
	}
}
