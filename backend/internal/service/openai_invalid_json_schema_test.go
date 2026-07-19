package service

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/model"
	"github.com/Wei-Shaw/sub2api/internal/pkg/tlsfingerprint"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

const invalidJSONSchemaBody = `{"error":{"message":"Invalid schema for response_format 'codex_output_schema'","type":"invalid_request_error","param":"text.format.schema","code":"invalid_json_schema","internal":"must-not-leak"}}`

type invalidJSONSchemaAccountRepo struct {
	AccountRepository
	tempUnschedulableCalls int
	setErrorCalls          int
}

func (r *invalidJSONSchemaAccountRepo) SetTempUnschedulable(_ context.Context, _ int64, _ time.Time, _ string) error {
	r.tempUnschedulableCalls++
	return nil
}

func (r *invalidJSONSchemaAccountRepo) SetError(_ context.Context, _ int64, _ string) error {
	r.setErrorCalls++
	return nil
}

func invalidJSONSchemaPenaltyAccount() *Account {
	return &Account{
		ID:          901,
		Name:        "invalid-schema-test",
		Platform:    PlatformOpenAI,
		Type:        AccountTypeAPIKey,
		Status:      StatusActive,
		Schedulable: true,
		Credentials: map[string]any{
			"temp_unschedulable_enabled": true,
			"temp_unschedulable_rules": []any{map[string]any{
				"error_code":       float64(http.StatusUnprocessableEntity),
				"keywords":         []any{"invalid_json_schema"},
				"duration_minutes": float64(10),
			}},
		},
	}
}

func newInvalidJSONSchemaService(repo AccountRepository) *OpenAIGatewayService {
	return &OpenAIGatewayService{
		rateLimitService: NewRateLimitService(repo, nil, &config.Config{}, nil, nil),
	}
}

func newInvalidJSONSchemaContext() (*gin.Context, *httptest.ResponseRecorder) {
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", nil)
	return c, rec
}

func TestParseOpenAIInvalidJSONSchemaClientError_RequiresExactSignature(t *testing.T) {
	tests := []struct {
		name   string
		status int
		body   string
		match  bool
	}{
		{name: "400 exact", status: http.StatusBadRequest, body: invalidJSONSchemaBody, match: true},
		{name: "422 exact", status: http.StatusUnprocessableEntity, body: invalidJSONSchemaBody, match: true},
		{name: "wrong status", status: http.StatusConflict, body: invalidJSONSchemaBody},
		{name: "wrong type", status: http.StatusBadRequest, body: `{"error":{"type":"upstream_error","code":"invalid_json_schema"}}`},
		{name: "wrong code", status: http.StatusBadRequest, body: `{"error":{"type":"invalid_request_error","code":"server_is_overloaded"}}`},
		{name: "missing code", status: http.StatusUnprocessableEntity, body: `{"error":{"type":"invalid_request_error"}}`},
		{name: "malformed JSON", status: http.StatusBadRequest, body: `{"error":`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, matched := parseOpenAIInvalidJSONSchemaClientError(tt.status, []byte(tt.body))
			require.Equal(t, tt.match, matched)
		})
	}
}

func TestParseOpenAIInvalidJSONSchemaClientError_SanitizesAndTruncatesFields(t *testing.T) {
	longMessage := "schema failed ?access_token=secret-value " + strings.Repeat("x", openAIInvalidJSONSchemaMaxMessage)
	body, err := json.Marshal(map[string]any{"error": map[string]any{
		"message": longMessage,
		"type":    openAIInvalidJSONSchemaErrorType,
		"code":    openAIInvalidJSONSchemaErrorCode,
		"param":   strings.Repeat("p", openAIInvalidJSONSchemaMaxParam+10),
	}})
	require.NoError(t, err)

	parsed, matched := parseOpenAIInvalidJSONSchemaClientError(http.StatusBadRequest, body)
	require.True(t, matched)
	require.NotContains(t, parsed.Message, "secret-value")
	require.Contains(t, parsed.Message, "access_token=***")
	require.LessOrEqual(t, len(parsed.Message), openAIInvalidJSONSchemaMaxMessage)
	require.Len(t, parsed.Param, openAIInvalidJSONSchemaMaxParam)
}

func TestOpenAIInvalidJSONSchema_DoesNotPenalizeAccount(t *testing.T) {
	tests := []struct {
		name string
		run  func(*OpenAIGatewayService, *gin.Context, *Account) error
	}{
		{
			name: "normal",
			run: func(svc *OpenAIGatewayService, c *gin.Context, account *Account) error {
				resp := &http.Response{
					StatusCode: http.StatusUnprocessableEntity,
					Body:       io.NopCloser(strings.NewReader(invalidJSONSchemaBody)),
					Header:     http.Header{"X-Request-Id": []string{"schema-normal"}, "X-Internal-Upstream": []string{"must-not-leak"}},
				}
				_, err := svc.handleErrorResponse(context.Background(), resp, c, account, nil)
				return err
			},
		},
		{
			name: "passthrough",
			run: func(svc *OpenAIGatewayService, c *gin.Context, account *Account) error {
				resp := &http.Response{
					StatusCode: http.StatusUnprocessableEntity,
					Header:     http.Header{"X-Request-Id": []string{"schema-passthrough"}, "X-Internal-Upstream": []string{"must-not-leak"}},
				}
				return svc.handleErrorResponsePassthrough(
					context.Background(), resp, c, account, nil, []byte(invalidJSONSchemaBody),
				)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := &invalidJSONSchemaAccountRepo{}
			svc := newInvalidJSONSchemaService(repo)
			account := invalidJSONSchemaPenaltyAccount()
			c, rec := newInvalidJSONSchemaContext()

			err := tt.run(svc, c, account)
			require.Error(t, err)
			require.Equal(t, http.StatusUnprocessableEntity, rec.Code)
			require.Empty(t, rec.Header().Get("X-Request-Id"))
			require.Empty(t, rec.Header().Get("X-Internal-Upstream"))
			require.NotContains(t, rec.Body.String(), "must-not-leak")
			require.Zero(t, repo.tempUnschedulableCalls)
			require.Zero(t, repo.setErrorCalls)
			require.Nil(t, account.TempUnschedulableUntil)
			require.Empty(t, account.TempUnschedulableReason)

			var response map[string]any
			require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &response))
			require.Equal(t, openAIInvalidJSONSchemaErrorType, response["error"].(map[string]any)["type"])
			events := c.MustGet(OpsUpstreamErrorsKey).([]*OpsUpstreamErrorEvent)
			require.Len(t, events, 1)
			require.Equal(t, "http_error", events[0].Kind)
			require.Equal(t, OpsClientBusinessLimitedReasonUpstreamInvalidRequest, events[0].Reason)
		})
	}
}

func TestOpenAIInvalidJSONSchema_PassthroughAdminRuleTakesPriority(t *testing.T) {
	repo := &invalidJSONSchemaAccountRepo{}
	svc := newInvalidJSONSchemaService(repo)
	account := invalidJSONSchemaPenaltyAccount()
	c, rec := newInvalidJSONSchemaContext()

	ruleSvc := &ErrorPassthroughService{}
	ruleSvc.setLocalCache([]*model.ErrorPassthroughRule{
		newNonFailoverPassthroughRule(
			http.StatusUnprocessableEntity,
			"invalid schema",
			http.StatusTeapot,
			"管理员定义的 schema 错误",
		),
	})
	BindErrorPassthroughService(c, ruleSvc)
	resp := &http.Response{
		StatusCode: http.StatusUnprocessableEntity,
		Header:     http.Header{"X-Request-Id": []string{"schema-admin-rule"}},
	}

	err := svc.handleErrorResponsePassthrough(
		context.Background(), resp, c, account, nil, []byte(invalidJSONSchemaBody),
	)
	require.Error(t, err)
	var failoverErr *UpstreamFailoverError
	require.False(t, errors.As(err, &failoverErr))
	require.Equal(t, http.StatusTeapot, rec.Code)
	require.True(t, IsResponseCommitted(c))
	require.Zero(t, repo.tempUnschedulableCalls)
	require.Zero(t, repo.setErrorCalls)

	var payload map[string]any
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &payload))
	require.Equal(t, map[string]any{
		"error": map[string]any{
			"type":    "upstream_error",
			"message": "管理员定义的 schema 错误",
		},
	}, payload)
}

type invalidJSONSchemaRealHTTPUpstream struct {
	client *http.Client
}

func (u *invalidJSONSchemaRealHTTPUpstream) Do(req *http.Request, _ string, _ int64, _ int) (*http.Response, error) {
	return u.client.Do(req)
}

func (u *invalidJSONSchemaRealHTTPUpstream) DoWithTLS(req *http.Request, _ string, _ int64, _ int, _ *tlsfingerprint.Profile) (*http.Response, error) {
	return u.client.Do(req)
}

func TestOpenAIInvalidJSONSchema_ForwardUsesRealHTTPOnceForNormalAndPassthrough(t *testing.T) {
	for _, passthrough := range []bool{false, true} {
		t.Run(map[bool]string{false: "normal", true: "passthrough"}[passthrough], func(t *testing.T) {
			const upstreamRequestID = "upstream-schema-http-1"
			var upstreamCalls atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				upstreamCalls.Add(1)
				require.Equal(t, http.MethodPost, r.Method)
				require.Equal(t, "/v1/responses", r.URL.Path)
				require.Equal(t, "Bearer sk-schema-test", r.Header.Get("Authorization"))
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("X-Request-Id", upstreamRequestID)
				w.WriteHeader(http.StatusBadRequest)
				_, _ = io.WriteString(w, invalidJSONSchemaBody)
			}))
			defer upstream.Close()

			cfg := &config.Config{}
			cfg.Security.URLAllowlist.AllowInsecureHTTP = true
			svc := &OpenAIGatewayService{
				cfg:          cfg,
				httpUpstream: &invalidJSONSchemaRealHTTPUpstream{client: upstream.Client()},
			}
			account := &Account{
				ID:          902,
				Name:        "http-account",
				Platform:    PlatformOpenAI,
				Type:        AccountTypeAPIKey,
				Concurrency: 1,
				Credentials: map[string]any{"api_key": "sk-schema-test", "base_url": upstream.URL},
				Extra:       map[string]any{"openai_passthrough": passthrough, "use_responses_api": true},
				Status:      StatusActive,
				Schedulable: true,
			}
			requestBody := []byte(`{"model":"gpt-5.6-sol","stream":false,"input":"hello"}`)
			c, rec := newInvalidJSONSchemaContext()
			c.Request.Body = io.NopCloser(strings.NewReader(string(requestBody)))
			c.Request.Header.Set("Content-Type", "application/json")

			result, err := svc.Forward(context.Background(), c, account, requestBody)
			require.Error(t, err)
			require.Nil(t, result)
			require.Equal(t, http.StatusBadRequest, rec.Code)
			require.Equal(t, int32(1), upstreamCalls.Load())
			require.Contains(t, rec.Body.String(), `"code":"invalid_json_schema"`)
			events := c.MustGet(OpsUpstreamErrorsKey).([]*OpsUpstreamErrorEvent)
			require.Len(t, events, 1)
			require.Equal(t, upstreamRequestID, events[0].UpstreamRequestID)
			require.Equal(t, passthrough, events[0].Passthrough)
		})
	}
}
