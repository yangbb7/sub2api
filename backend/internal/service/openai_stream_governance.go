package service

import (
	"context"
	"hash/fnv"
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/pkg/ctxkey"
	"github.com/gin-gonic/gin"
)

type openAIStreamGovernanceContextKey struct{}

type openAIStreamGovernancePlan struct {
	enabled                bool
	totalDeadline          time.Time
	firstAttemptBudget     time.Duration
	backupAttemptBudget    time.Duration
	firstAttemptClaimed    bool
	currentAttemptTimeout  time.Duration
	currentAttemptDeadline time.Time
	mu                     sync.Mutex
}

func (p *openAIStreamGovernancePlan) claimAttemptTimeout(now time.Time) time.Duration {
	timeout, _ := p.claimAttempt(now)
	return timeout
}

func (p *openAIStreamGovernancePlan) claimAttempt(now time.Time) (time.Duration, time.Time) {
	if p == nil || !p.enabled {
		return 0, time.Time{}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	remaining := p.totalDeadline.Sub(now)
	if remaining <= 0 {
		p.currentAttemptTimeout = time.Nanosecond
		p.currentAttemptDeadline = now.Add(time.Nanosecond)
		return p.currentAttemptTimeout, p.currentAttemptDeadline
	}
	var deadline time.Time
	if !p.firstAttemptClaimed {
		p.firstAttemptClaimed = true
		deadline = now.Add(p.firstAttemptBudget)
		firstDeadline := p.totalDeadline.Add(-p.backupAttemptBudget)
		if p.backupAttemptBudget <= 0 {
			firstDeadline = deadline
		}
		if firstDeadline.Before(deadline) {
			deadline = firstDeadline
		}
	} else {
		deadline = now.Add(p.backupAttemptBudget)
	}
	if deadline.After(p.totalDeadline) {
		deadline = p.totalDeadline
	}
	timeout := deadline.Sub(now)
	if timeout <= 0 {
		timeout = time.Nanosecond
		deadline = now.Add(timeout)
	}
	p.currentAttemptTimeout = timeout
	p.currentAttemptDeadline = deadline
	return timeout, deadline
}

func (p *openAIStreamGovernancePlan) currentAttempt() (time.Duration, time.Time, bool) {
	if p == nil || !p.enabled {
		return 0, time.Time{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.currentAttemptDeadline.IsZero() || p.currentAttemptTimeout <= 0 {
		return 0, time.Time{}, false
	}
	return p.currentAttemptTimeout, p.currentAttemptDeadline, true
}

func withOpenAIStreamGovernancePlan(ctx context.Context, plan *openAIStreamGovernancePlan) context.Context {
	if plan == nil {
		return ctx
	}
	return context.WithValue(ctx, openAIStreamGovernanceContextKey{}, plan)
}

func openAIStreamGovernancePlanFromContext(ctx context.Context) *openAIStreamGovernancePlan {
	if ctx == nil {
		return nil
	}
	plan, _ := ctx.Value(openAIStreamGovernanceContextKey{}).(*openAIStreamGovernancePlan)
	return plan
}

func openAIStreamGovernanceActive(ctx context.Context) bool {
	plan := openAIStreamGovernancePlanFromContext(ctx)
	return plan != nil && plan.enabled
}

// WithOpenAIStreamGovernancePlan applies the deterministic rollout decision to
// this request. The decision is keyed by the gateway request ID so retries do
// not drift between cohorts. reserveBackup is true only when the handler has
// established that a pre-semantic cross-account replay is safe. Stateful
// Responses turns (tools, continuations, and requests without caller
// idempotency) cannot use a backup account, so their sole attempt receives the
// complete total budget rather than being cut off at the first-attempt budget.
func (s *OpenAIGatewayService) WithOpenAIStreamGovernancePlan(c *gin.Context, startedAt time.Time, reserveBackup bool) context.Context {
	if c == nil || c.Request == nil || s == nil || s.cfg == nil {
		return nil
	}
	ctx := c.Request.Context()
	cfg := s.cfg.Gateway.OpenAIStreamGovernance
	if !cfg.Enabled || cfg.RolloutPercent <= 0 || !openAIStreamGovernanceInRollout(ctx, cfg.RolloutPercent) {
		return ctx
	}
	if startedAt.IsZero() {
		startedAt = time.Now()
	}
	firstAttemptBudget := time.Duration(cfg.FirstAttemptBudgetSeconds) * time.Second
	backupAttemptBudget := time.Duration(cfg.TotalBudgetSeconds-cfg.FirstAttemptBudgetSeconds) * time.Second
	if !reserveBackup {
		firstAttemptBudget = time.Duration(cfg.TotalBudgetSeconds) * time.Second
		backupAttemptBudget = 0
	}
	plan := &openAIStreamGovernancePlan{
		enabled:             true,
		totalDeadline:       startedAt.Add(time.Duration(cfg.TotalBudgetSeconds) * time.Second),
		firstAttemptBudget:  firstAttemptBudget,
		backupAttemptBudget: backupAttemptBudget,
	}
	return withOpenAIStreamGovernancePlan(ctx, plan)
}

func openAIStreamGovernanceInRollout(ctx context.Context, percent int) bool {
	if percent >= 100 {
		return true
	}
	if percent <= 0 {
		return false
	}
	requestID, _ := ctx.Value(ctxkey.RequestID).(string)
	requestID = strings.TrimSpace(requestID)
	if requestID == "" {
		return false
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(requestID))
	return int(h.Sum32()%100) < percent
}

func (s *OpenAIGatewayService) openAIFirstOutputTimeoutForRequest(ctx context.Context, reasoningEffort string) time.Duration {
	timeout := s.openAIFirstOutputTimeout(reasoningEffort)
	if plan := openAIStreamGovernancePlanFromContext(ctx); plan != nil && plan.enabled {
		budget, _ := plan.claimAttempt(time.Now())
		if timeout <= 0 || budget < timeout {
			return budget
		}
	}
	return timeout
}

func (s *OpenAIGatewayService) openAIFirstOutputTimeoutForCurrentAttempt(ctx context.Context, reasoningEffort string) time.Duration {
	if plan := openAIStreamGovernancePlanFromContext(ctx); plan != nil && plan.enabled {
		if timeout, _, ok := plan.currentAttempt(); ok {
			return timeout
		}
	}
	return s.openAIFirstOutputTimeoutForRequest(ctx, reasoningEffort)
}

func openAIFirstOutputDeadlineForRequest(ctx context.Context, startTime time.Time, timeout time.Duration) time.Time {
	if plan := openAIStreamGovernancePlanFromContext(ctx); plan != nil && plan.enabled {
		if _, deadline, ok := plan.currentAttempt(); ok {
			return deadline
		}
	}
	if timeout <= 0 {
		return time.Time{}
	}
	return startTime.Add(timeout)
}

type openAIStreamHealthEvent struct {
	at           time.Time
	ttftMs       int
	hasTTFT      bool
	firstTimeout bool
	preCancel    bool
}

type openAIStreamHealthSnapshot struct {
	TTFT5mMs           float64
	TTFT15mMs          float64
	FirstTimeoutRate5m float64
	PreCancelRate5m    float64
	CircuitOpen        bool
	Samples15m         int
}

func (s *openAIAccountRuntimeStats) reportStreamHealth(accountID int64, firstTokenMs *int, outcome string, policy config.GatewayOpenAIStreamGovernanceConfig) {
	if s == nil || accountID <= 0 {
		return
	}
	stat := s.loadOrCreate(accountID)
	if stat == nil {
		return
	}
	policy = normalizedOpenAIStreamGovernancePolicy(policy)
	now := time.Now()
	event := openAIStreamHealthEvent{at: now}
	if firstTokenMs != nil && *firstTokenMs >= 0 {
		event.ttftMs, event.hasTTFT = *firstTokenMs, true
	}
	switch outcome {
	case "first_output_timeout":
		event.firstTimeout = true
	case "presemantic_cancel":
		event.preCancel = true
	}
	stat.streamHealthMu.Lock()
	stat.streamHealthEvents = append(stat.streamHealthEvents, event)
	stat.streamHealthEvents = pruneOpenAIStreamHealthEvents(stat.streamHealthEvents, now.Add(-15*time.Minute))
	snapshot := summarizeOpenAIStreamHealth(stat.streamHealthEvents, now, stat.streamCircuitUntil.After(now), stat.streamCircuitUntil)
	slowTTFT := snapshot.TTFT5mMs > float64(policy.HealthTTFTMs)
	if snapshot.Samples15m >= policy.CircuitMinSamples && (slowTTFT ||
		(snapshot.FirstTimeoutRate5m+snapshot.PreCancelRate5m) >= float64(policy.CircuitFailureRatePercent)/100) {
		stat.streamCircuitUntil = now.Add(time.Duration(policy.CircuitCooldownSeconds) * time.Second)
	}
	stat.streamHealthMu.Unlock()
}

func (s *openAIAccountRuntimeStats) streamHealthSnapshot(accountID int64) openAIStreamHealthSnapshot {
	if s == nil || accountID <= 0 {
		return openAIStreamHealthSnapshot{}
	}
	v, ok := s.accounts.Load(accountID)
	if !ok {
		return openAIStreamHealthSnapshot{}
	}
	stat, _ := v.(*openAIAccountRuntimeStat)
	if stat == nil {
		return openAIStreamHealthSnapshot{}
	}
	now := time.Now()
	stat.streamHealthMu.Lock()
	stat.streamHealthEvents = pruneOpenAIStreamHealthEvents(stat.streamHealthEvents, now.Add(-15*time.Minute))
	snapshot := summarizeOpenAIStreamHealth(stat.streamHealthEvents, now, stat.streamCircuitUntil.After(now), stat.streamCircuitUntil)
	stat.streamHealthMu.Unlock()
	return snapshot
}

func pruneOpenAIStreamHealthEvents(events []openAIStreamHealthEvent, cutoff time.Time) []openAIStreamHealthEvent {
	index := 0
	for _, event := range events {
		if !event.at.Before(cutoff) {
			events[index] = event
			index++
		}
	}
	return events[:index]
}

func summarizeOpenAIStreamHealth(events []openAIStreamHealthEvent, now time.Time, circuitOpen bool, _ time.Time) openAIStreamHealthSnapshot {
	var out openAIStreamHealthSnapshot
	var ttft5, ttft15 float64
	var ttft5Count, ttft15Count, fiveMinuteCount, timeouts5, cancels5 int
	fiveMinuteAgo := now.Add(-5 * time.Minute)
	for _, event := range events {
		out.Samples15m++
		if event.hasTTFT {
			ttft15 += float64(event.ttftMs)
			ttft15Count++
			if !event.at.Before(fiveMinuteAgo) {
				ttft5 += float64(event.ttftMs)
				ttft5Count++
			}
		}
		if event.at.Before(fiveMinuteAgo) {
			continue
		}
		fiveMinuteCount++
		if event.firstTimeout {
			timeouts5++
		}
		if event.preCancel {
			cancels5++
		}
	}
	if ttft5Count > 0 {
		out.TTFT5mMs = ttft5 / float64(ttft5Count)
	}
	if ttft15Count > 0 {
		out.TTFT15mMs = ttft15 / float64(ttft15Count)
	}
	if fiveMinuteCount > 0 {
		out.FirstTimeoutRate5m = float64(timeouts5) / float64(fiveMinuteCount)
		out.PreCancelRate5m = float64(cancels5) / float64(fiveMinuteCount)
	}
	out.CircuitOpen = circuitOpen
	return out
}

func (s *OpenAIGatewayService) ReportOpenAIStreamAttempt(accountID int64, firstTokenMs *int, outcome string) {
	if s == nil || s.openaiAccountStats == nil || s.cfg == nil {
		return
	}
	s.openaiAccountStats.reportStreamHealth(accountID, firstTokenMs, outcome, s.cfg.Gateway.OpenAIStreamGovernance)
}

func streamHealthCircuitOpen(snapshot openAIStreamHealthSnapshot) bool { return snapshot.CircuitOpen }

func normalizedOpenAIStreamGovernancePolicy(policy config.GatewayOpenAIStreamGovernanceConfig) config.GatewayOpenAIStreamGovernanceConfig {
	if policy.HealthTTFTMs <= 0 {
		policy.HealthTTFTMs = 8000
	}
	if policy.CircuitMinSamples <= 0 {
		policy.CircuitMinSamples = 3
	}
	if policy.CircuitFailureRatePercent <= 0 {
		policy.CircuitFailureRatePercent = 50
	}
	if policy.CircuitCooldownSeconds <= 0 {
		policy.CircuitCooldownSeconds = 300
	}
	return policy
}
