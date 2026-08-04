package service

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/ctxkey"
	"github.com/Wei-Shaw/sub2api/internal/pkg/logger"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

type streamAttemptSink struct{ events []*logger.LogEvent }

func (s *streamAttemptSink) WriteLogEvent(event *logger.LogEvent) { s.events = append(s.events, event) }

func TestStreamAttemptFinalizationIsPrivacySafeAndCapturesPreSemanticCancel(t *testing.T) {
	gin.SetMode(gin.TestMode)
	sink := &streamAttemptSink{}
	logger.SetSink(sink)
	t.Cleanup(func() { logger.SetSink(nil) })

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	ctx := context.WithValue(context.Background(), ctxkey.RequestID, "request-1")
	ctx, cancel := context.WithCancel(ctx)
	c.Request = httptest.NewRequest("POST", "/v1/responses", nil).WithContext(ctx)
	c.Request.Header.Set("CF-Ray", "ray-1")
	c.Request.Header.Set("User-Agent", "Codex Desktop")

	StartStreamAttempt(c, time.Now().Add(-10*time.Millisecond), make([]byte, 5*1024*1024), "gpt-5", true)
	StreamAttemptMarkSelectedAccount(c, &Account{ID: 42, Platform: PlatformOpenAI, Name: "never-recorded"})
	StreamAttemptMarkUpstreamResponseHeaders(c)
	cancel()
	FinalizeStreamAttempt(c)

	require.Len(t, sink.events, 1)
	event := sink.events[0]
	require.Equal(t, "stream_attempts", event.Component)
	require.Equal(t, "stream_attempt.completed", event.Message)
	require.Equal(t, "request-1", event.Fields["request_id"])
	require.Equal(t, "ray-1", event.Fields["cf_ray"])
	require.Equal(t, "codex_desktop", event.Fields["client_type"])
	require.Equal(t, "4m_8m", event.Fields["request_body_bucket"])
	require.Equal(t, int64(42), event.Fields["selected_account_id"])
	require.Equal(t, "after_headers_before_semantic", event.Fields["cancel_phase"])
	require.Equal(t, "client_canceled", event.Fields["final_outcome"])
	require.NotContains(t, event.Fields, "selected_account_name")
	require.NotContains(t, event.Fields, "request_body")
}

func TestStreamAttemptBodyBucketsAndClientClassification(t *testing.T) {
	require.Equal(t, "0_64k", streamAttemptBodyBucket(1))
	require.Equal(t, "64k_256k", streamAttemptBodyBucket(64*1024+1))
	require.Equal(t, "1m_4m", streamAttemptBodyBucket(1024*1024+1))
	require.Equal(t, "gt_8m", streamAttemptBodyBucket(8*1024*1024+1))
	require.Equal(t, "codex", classifyStreamClient("codex-cli/1"))
	require.Equal(t, "other", classifyStreamClient("curl/8"))
}

func TestStreamAttemptPreSemanticCancelCanOnlyBeClaimedOnce(t *testing.T) {
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest("POST", "/v1/responses", nil)
	StartStreamAttempt(c, time.Now(), []byte("{}"), "gpt-5", true)
	require.True(t, StreamAttemptClaimPreSemanticCancel(c))
	require.False(t, StreamAttemptClaimPreSemanticCancel(c))
	StreamAttemptMarkFirstSemanticEvent(c)
	require.False(t, StreamAttemptClaimPreSemanticCancel(c))
}
