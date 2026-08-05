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

func TestConfigureResponsesStreamKeepaliveCohort(t *testing.T) {
	gin.SetMode(gin.TestMode)
	newContext := func(requestID string) *gin.Context {
		c, _ := gin.CreateTestContext(httptest.NewRecorder())
		req := httptest.NewRequest(http.MethodPost, "/v1/responses", nil)
		c.Request = req.WithContext(context.WithValue(req.Context(), ctxkey.RequestID, requestID))
		return c
	}
	newConfig := func(enabled bool, percent int) *config.Config {
		return &config.Config{Gateway: config.GatewayConfig{
			StreamKeepaliveInterval: 5,
			OpenAIStreamGovernance: config.GatewayOpenAIStreamGovernanceConfig{
				Enabled:        enabled,
				RolloutPercent: percent,
			},
		}}
	}

	c := newContext("responses-keepalive-canary")
	ConfigureResponsesStreamKeepaliveCohort(c, newConfig(true, 100))
	require.True(t, responsesStreamKeepaliveCohortEnabled(c))
	require.Equal(t, 5*time.Second, responsesStreamKeepaliveInterval(c, newConfig(true, 100)))

	c = newContext("responses-keepalive-canary")
	ConfigureResponsesStreamKeepaliveCohort(c, newConfig(true, 0))
	require.True(t, responsesStreamKeepaliveCohortEnabled(c))
	require.Equal(t, 5*time.Second, responsesStreamKeepaliveInterval(c, newConfig(true, 0)))

	c = newContext("responses-keepalive-canary")
	ConfigureResponsesStreamKeepaliveCohort(c, newConfig(false, 100))
	require.True(t, responsesStreamKeepaliveCohortEnabled(c))

	first := newContext("responses-keepalive-canary")
	second := newContext("responses-keepalive-canary")
	canaryConfig := newConfig(true, 10)
	ConfigureResponsesStreamKeepaliveCohort(first, canaryConfig)
	ConfigureResponsesStreamKeepaliveCohort(second, canaryConfig)
	require.Equal(t, responsesStreamKeepaliveCohortEnabled(first), responsesStreamKeepaliveCohortEnabled(second))
}

func TestResponsesStreamKeepaliveCohortLeavesUnmarkedStreamsCompatible(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/messages", nil)
	cfg := &config.Config{Gateway: config.GatewayConfig{StreamKeepaliveInterval: 5}}

	require.True(t, responsesStreamKeepaliveCohortEnabled(c))
	require.Equal(t, 5*time.Second, responsesStreamKeepaliveInterval(c, cfg))
}
