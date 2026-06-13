package service

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestBuildUsageRequestSnapshotDropsGenerationParametersAndRedactsSecrets(t *testing.T) {
	t.Parallel()

	raw := []byte(`{
		"model":"gpt-5.5",
		"messages":[{"role":"user","content":"check this response"}],
		"temperature":0.7,
		"max_tokens":2048,
		"stream":true,
		"metadata":{"trace_id":"abc","secret":"do-not-store"},
		"api_key":"sk-live-secret"
	}`)

	snapshot := BuildUsageRequestSnapshot(raw)

	require.NotNil(t, snapshot)
	require.False(t, snapshot.Truncated)
	require.Contains(t, snapshot.Content, `"model": "gpt-5.5"`)
	require.Contains(t, snapshot.Content, "check this response")
	require.NotContains(t, snapshot.Content, "temperature")
	require.NotContains(t, snapshot.Content, "max_tokens")
	require.NotContains(t, snapshot.Content, "stream")
	require.NotContains(t, snapshot.Content, "sk-live-secret")
	require.NotContains(t, snapshot.Content, "do-not-store")
	require.Contains(t, snapshot.Content, "[REDACTED]")
}

func TestBuildUsageResponseSnapshotLimitsContent(t *testing.T) {
	t.Parallel()

	raw := []byte(`{"id":"resp_1","output_text":"` + strings.Repeat("x", maxUsageCallSnapshotBytes+128) + `"}`)

	snapshot := BuildUsageResponseSnapshot(raw)

	require.NotNil(t, snapshot)
	require.True(t, snapshot.Truncated)
	require.LessOrEqual(t, len(snapshot.Content), maxUsageCallSnapshotBytes)
}

func TestBuildUsageResponseSnapshotRedactsSecretsFromPlainText(t *testing.T) {
	t.Parallel()

	raw := []byte("upstream error: Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456 and key sk-live-secret-token")

	snapshot := BuildUsageResponseSnapshot(raw)

	require.NotNil(t, snapshot)
	require.NotContains(t, snapshot.Content, "abcdefghijklmnopqrstuvwxyz123456")
	require.NotContains(t, snapshot.Content, "sk-live-secret-token")
	require.Contains(t, snapshot.Content, "Bearer [REDACTED]")
	require.Contains(t, snapshot.Content, "[REDACTED]")
}

func TestUsageCallSnapshotCollectorCapturesLimitedStreamSample(t *testing.T) {
	t.Parallel()

	collector := newUsageCallSnapshotCollector()
	collector.AppendString("data: ")
	collector.AppendString(strings.Repeat("x", maxUsageCallSnapshotBytes+128))

	snapshot := collector.Snapshot()

	require.NotNil(t, snapshot)
	require.True(t, snapshot.Truncated)
	require.LessOrEqual(t, len(snapshot.Content), maxUsageCallSnapshotBytes)
}
