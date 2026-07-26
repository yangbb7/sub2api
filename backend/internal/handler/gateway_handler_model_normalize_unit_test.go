//go:build unit

package handler

import (
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"

	"github.com/stretchr/testify/require"
	"github.com/tidwall/gjson"
)

func TestNormalizeAntigravityClaudeModelRequest(t *testing.T) {
	body := []byte(`{"model":"claude-opus-4.7","max_tokens":16,"messages":[{"role":"user","content":"hello"}]}`)
	parsedReq := &service.ParsedRequest{
		Model: "claude-opus-4.7",
		Body:  service.NewRequestBodyRef(body),
	}

	got, err := normalizeAntigravityClaudeModelRequest(body, parsedReq)
	require.NoError(t, err)

	require.Equal(t, "claude-opus-4-7", parsedReq.Model)
	require.Equal(t, "claude-opus-4-7", gjson.GetBytes(got, "model").String())
	require.Equal(t, got, parsedReq.Body.Bytes())
}

func TestNormalizeAntigravityClaudeModelRequest_PreservesCanonicalModel(t *testing.T) {
	body := []byte(`{"model":"claude-opus-4-7","max_tokens":16,"messages":[]}`)
	parsedReq := &service.ParsedRequest{
		Model: "claude-opus-4-7",
		Body:  service.NewRequestBodyRef(body),
	}

	got, err := normalizeAntigravityClaudeModelRequest(body, parsedReq)
	require.NoError(t, err)

	require.Equal(t, "claude-opus-4-7", parsedReq.Model)
	require.Equal(t, body, got)
	require.Equal(t, body, parsedReq.Body.Bytes())
}
