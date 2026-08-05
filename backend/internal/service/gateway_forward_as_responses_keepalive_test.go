package service

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/pkg/apicompat"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestGatewayResponsesForwarderEmitsKeepaliveBeforeFirstUpstreamEvent(t *testing.T) {
	gin.SetMode(gin.TestMode)

	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", nil)
	StartStreamAttempt(c, time.Now(), []byte(`{"model":"claude-fable-5","stream":true,"input":"probe"}`), "claude-fable-5", true)
	StreamAttemptMarkUpstreamResponseHeaders(c)

	reader, writer := io.Pipe()
	response := &http.Response{Body: reader}
	service := &GatewayService{cfg: &config.Config{Gateway: config.GatewayConfig{
		MaxLineSize:             defaultMaxLineSize,
		StreamKeepaliveInterval: 1,
		OpenAIStreamGovernance: config.GatewayOpenAIStreamGovernanceConfig{
			Enabled:        true,
			RolloutPercent: 100,
		},
	}}}
	ConfigureResponsesStreamKeepaliveCohort(c, service.cfg)
	go func() {
		defer func() { _ = writer.Close() }()
		time.Sleep(1200 * time.Millisecond)
		_, _ = io.WriteString(writer, strings.Join([]string{
			`event: message_start`,
			`data: {"type":"message_start","message":{"id":"msg_keepalive","type":"message","role":"assistant","content":[],"model":"claude-fable-5","usage":{"input_tokens":1}}}`,
			``,
			`event: message_stop`,
			`data: {"type":"message_stop"}`,
			``,
		}, "\n"))
	}()

	result, err := service.handleResponsesStreamingResponse(
		response,
		c,
		"claude-fable-5",
		"claude-fable-5",
		nil,
		time.Now(),
		apicompat.ResponsesClientToolMapping{},
	)
	require.NoError(t, err)
	require.NotNil(t, result)
	require.True(t, strings.HasPrefix(recorder.Body.String(), ":\n\n"), "heartbeat must precede a delayed upstream event")
	attempt := streamAttemptFromContext(c)
	require.NotNil(t, attempt)
	require.GreaterOrEqual(t, attempt.downstreamKeepaliveCount, 1)
	require.False(t, attempt.firstDownstreamAt.IsZero())
}

func TestGatewayResponsesForwarderKeepaliveRolloutZeroOverHTTP(t *testing.T) {
	gin.SetMode(gin.TestMode)
	service := &GatewayService{cfg: &config.Config{Gateway: config.GatewayConfig{
		MaxLineSize:             defaultMaxLineSize,
		StreamKeepaliveInterval: 5,
		OpenAIStreamGovernance: config.GatewayOpenAIStreamGovernanceConfig{
			Enabled: true, RolloutPercent: 0,
		},
	}}}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, _ := gin.CreateTestContext(w)
		c.Request = r
		StartStreamAttempt(c, time.Now(), []byte(`{"model":"claude-fable-5","stream":true,"input":"probe"}`), "claude-fable-5", true)
		// This is the real upstream-header boundary. No keepalive is allowed before it.
		StreamAttemptMarkUpstreamResponseHeaders(c)
		ConfigureResponsesStreamKeepaliveCohort(c, service.cfg)

		reader, writer := io.Pipe()
		defer func() { _ = reader.Close() }()
		go func() {
			defer func() { _ = writer.Close() }()
			time.Sleep(5200 * time.Millisecond)
			_, _ = io.WriteString(writer, strings.Join([]string{
				`event: message_start`,
				`data: {"type":"message_start","message":{"id":"msg_keepalive","type":"message","role":"assistant","content":[],"model":"claude-fable-5","usage":{"input_tokens":1}}}`,
				``,
				`event: message_stop`,
				`data: {"type":"message_stop"}`,
				``,
			}, "\n"))
		}()

		_, _ = service.handleResponsesStreamingResponse(
			&http.Response{Body: reader}, c, "claude-fable-5", "claude-fable-5", nil, time.Now(), apicompat.ResponsesClientToolMapping{},
		)
	}))
	defer server.Close()

	response, err := http.Get(server.URL)
	require.NoError(t, err)
	defer func() { _ = response.Body.Close() }()
	firstFrame := make([]byte, len(":\n\n"))
	_, err = io.ReadFull(response.Body, firstFrame)
	require.NoError(t, err)
	require.Equal(t, ":\n\n", string(firstFrame))
}
