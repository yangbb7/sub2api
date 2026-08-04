package service

import (
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/ctxkey"
	"github.com/Wei-Shaw/sub2api/internal/pkg/logger"
	"github.com/gin-gonic/gin"
)

// StreamAttempt is a privacy-safe, request-scoped record for a streaming
// attempt. It intentionally contains no prompt, response body, credential, or
// raw user-agent data. The record is emitted through the Ops system-log sink as
// component=stream_attempts, which gives cancellations a durable trace even
// when they never reach usage accounting.
type StreamAttempt struct {
	mu sync.Mutex

	startedAt time.Time

	requestID  string
	cfRay      string
	clientType string
	bodyBucket string
	model      string
	// reasoningEffort is a normalized finite enum (unspecified/low/medium/high/
	// xhigh/max), never a raw value from the request body.
	reasoningEffort string
	stream          bool
	accountID       int64
	platform        string
	attempts        int

	upstreamHeadersAt         time.Time
	firstSemanticAt           time.Time
	firstDownstreamAt         time.Time
	cancelPhase               string
	outcome                   string
	presemanticCancelReported bool
	finalized                 bool
}

const streamAttemptContextKey = "stream_attempt"

// StartStreamAttempt installs an attempt record for a /responses request.
// Callers should defer FinalizeStreamAttempt once request validation confirms
// that the request is streaming.
func StartStreamAttempt(c *gin.Context, startedAt time.Time, body []byte, model string, stream bool) *StreamAttempt {
	if c == nil || c.Request == nil || !stream {
		return nil
	}
	if startedAt.IsZero() {
		startedAt = time.Now()
	}
	requestID, _ := c.Request.Context().Value(ctxkey.RequestID).(string)
	reasoningEffort := "unspecified"
	if effort := extractOpenAIReasoningEffortFromBody(body, model); effort != nil {
		reasoningEffort = *effort
	}
	attempt := &StreamAttempt{
		startedAt:       startedAt,
		requestID:       strings.TrimSpace(requestID),
		cfRay:           boundedStreamAttemptValue(c.GetHeader("CF-Ray"), 128),
		clientType:      classifyStreamClient(c.GetHeader("User-Agent")),
		bodyBucket:      streamAttemptBodyBucket(len(body)),
		model:           boundedStreamAttemptValue(model, 160),
		reasoningEffort: reasoningEffort,
		stream:          true,
	}
	c.Set(streamAttemptContextKey, attempt)
	return attempt
}

func streamAttemptFromContext(c *gin.Context) *StreamAttempt {
	if c == nil {
		return nil
	}
	v, ok := c.Get(streamAttemptContextKey)
	if !ok {
		return nil
	}
	attempt, _ := v.(*StreamAttempt)
	return attempt
}

// StreamAttemptMarkSelectedAccount records selection without exposing account
// names, credentials, or upstream URLs.
func StreamAttemptMarkSelectedAccount(c *gin.Context, account *Account) {
	attempt := streamAttemptFromContext(c)
	if attempt == nil || account == nil {
		return
	}
	attempt.mu.Lock()
	attempt.accountID = account.ID
	attempt.platform = boundedStreamAttemptValue(account.Platform, 32)
	attempt.attempts++
	attempt.mu.Unlock()
}

// StreamAttemptMarkUpstreamResponseHeaders marks when the upstream response
// headers arrived. Header values are deliberately not persisted.
func StreamAttemptMarkUpstreamResponseHeaders(c *gin.Context) {
	attempt := streamAttemptFromContext(c)
	if attempt == nil {
		return
	}
	attempt.mu.Lock()
	if attempt.upstreamHeadersAt.IsZero() {
		attempt.upstreamHeadersAt = time.Now()
	}
	attempt.mu.Unlock()
}

// StreamAttemptMarkFirstSemanticEvent marks the first event that can produce
// client-visible semantic output; lifecycle events such as response.created do
// not call this method.
func StreamAttemptMarkFirstSemanticEvent(c *gin.Context) {
	attempt := streamAttemptFromContext(c)
	if attempt == nil {
		return
	}
	attempt.mu.Lock()
	if attempt.firstSemanticAt.IsZero() {
		attempt.firstSemanticAt = time.Now()
	}
	attempt.mu.Unlock()
}

// StreamAttemptMarkFirstDownstreamByte records the first byte written towards
// the client, including a keepalive comment. This distinguishes a slow
// upstream-header phase from downstream proxy buffering.
func StreamAttemptMarkFirstDownstreamByte(c *gin.Context) {
	attempt := streamAttemptFromContext(c)
	if attempt == nil {
		return
	}
	attempt.mu.Lock()
	if attempt.firstDownstreamAt.IsZero() {
		attempt.firstDownstreamAt = time.Now()
	}
	attempt.mu.Unlock()
}

func StreamAttemptMarkClientCanceled(c *gin.Context) {
	attempt := streamAttemptFromContext(c)
	if attempt == nil {
		return
	}
	attempt.mu.Lock()
	if attempt.cancelPhase == "" {
		switch {
		case attempt.upstreamHeadersAt.IsZero():
			attempt.cancelPhase = "before_upstream_headers"
		case attempt.firstSemanticAt.IsZero():
			attempt.cancelPhase = "after_headers_before_semantic"
		default:
			attempt.cancelPhase = "after_semantic_output"
		}
	}
	if attempt.outcome == "" {
		attempt.outcome = "client_canceled"
	}
	attempt.mu.Unlock()
}

// StreamAttemptClaimPreSemanticCancel returns true at most once per request,
// and only before a semantic stream event. It lets the streaming service and
// handler race-free deduplicate the account-health cancellation sample.
func StreamAttemptClaimPreSemanticCancel(c *gin.Context) bool {
	attempt := streamAttemptFromContext(c)
	if attempt == nil {
		return false
	}
	attempt.mu.Lock()
	defer attempt.mu.Unlock()
	if !attempt.firstSemanticAt.IsZero() || attempt.presemanticCancelReported {
		return false
	}
	attempt.presemanticCancelReported = true
	return true
}

func StreamAttemptMarkOutcome(c *gin.Context, outcome string) {
	attempt := streamAttemptFromContext(c)
	if attempt == nil {
		return
	}
	outcome = boundedStreamAttemptValue(outcome, 64)
	if outcome == "" {
		return
	}
	attempt.mu.Lock()
	if attempt.outcome == "" {
		attempt.outcome = outcome
	}
	attempt.mu.Unlock()
}

// FinalizeStreamAttempt emits exactly one stream_attempts record. It is safe
// to call from deferred handler cleanup after client cancellation.
func FinalizeStreamAttempt(c *gin.Context) {
	attempt := streamAttemptFromContext(c)
	if attempt == nil {
		return
	}
	attempt.mu.Lock()
	if attempt.finalized {
		attempt.mu.Unlock()
		return
	}
	attempt.finalized = true
	now := time.Now()
	if c != nil && c.Request != nil && c.Request.Context().Err() != nil && attempt.cancelPhase == "" {
		switch {
		case attempt.upstreamHeadersAt.IsZero():
			attempt.cancelPhase = "before_upstream_headers"
		case attempt.firstSemanticAt.IsZero():
			attempt.cancelPhase = "after_headers_before_semantic"
		default:
			attempt.cancelPhase = "after_semantic_output"
		}
	}
	if attempt.outcome == "" {
		if attempt.cancelPhase != "" {
			attempt.outcome = "client_canceled"
		} else if c != nil && c.Writer != nil && c.Writer.Status() >= 200 && c.Writer.Status() < 300 {
			attempt.outcome = "succeeded"
		} else {
			attempt.outcome = "failed"
		}
	}
	fields := map[string]any{
		"request_id":                   attempt.requestID,
		"cf_ray":                       attempt.cfRay,
		"client_type":                  attempt.clientType,
		"request_body_bucket":          attempt.bodyBucket,
		"model":                        attempt.model,
		"reasoning_effort":             attempt.reasoningEffort,
		"stream":                       attempt.stream,
		"selected_account_id":          attempt.accountID,
		"platform":                     attempt.platform,
		"account_attempt_count":        attempt.attempts,
		"upstream_response_headers_ms": streamAttemptElapsedMs(attempt.startedAt, attempt.upstreamHeadersAt),
		"first_semantic_event_ms":      streamAttemptElapsedMs(attempt.startedAt, attempt.firstSemanticAt),
		"first_downstream_byte_ms":     streamAttemptElapsedMs(attempt.startedAt, attempt.firstDownstreamAt),
		"cancel_phase":                 attempt.cancelPhase,
		"final_outcome":                attempt.outcome,
		"duration_ms":                  now.Sub(attempt.startedAt).Milliseconds(),
	}
	attempt.mu.Unlock()
	logger.WriteSinkEvent("info", "stream_attempts", "stream_attempt.completed", fields)
}

func streamAttemptElapsedMs(startedAt, markedAt time.Time) any {
	if startedAt.IsZero() || markedAt.IsZero() {
		return nil
	}
	ms := markedAt.Sub(startedAt).Milliseconds()
	if ms < 0 {
		return int64(0)
	}
	return ms
}

func streamAttemptBodyBucket(size int) string {
	switch {
	case size <= 64*1024:
		return "0_64k"
	case size <= 256*1024:
		return "64k_256k"
	case size <= 1024*1024:
		return "256k_1m"
	case size <= 4*1024*1024:
		return "1m_4m"
	case size <= 8*1024*1024:
		return "4m_8m"
	default:
		return "gt_8m"
	}
}

func classifyStreamClient(userAgent string) string {
	ua := strings.ToLower(strings.TrimSpace(userAgent))
	switch {
	case strings.Contains(ua, "codex") && strings.Contains(ua, "desktop"):
		return "codex_desktop"
	case strings.Contains(ua, "codex"):
		return "codex"
	case strings.Contains(ua, "openai"):
		return "openai_sdk"
	case ua == "":
		return "unknown"
	default:
		return "other"
	}
}

func boundedStreamAttemptValue(value string, max int) string {
	value = strings.TrimSpace(value)
	if max > 0 && len(value) > max {
		return value[:max]
	}
	return value
}
