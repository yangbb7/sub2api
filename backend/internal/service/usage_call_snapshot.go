package service

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strings"
)

const maxUsageCallSnapshotBytes = 16 * 1024

var usageRequestParameterKeys = map[string]struct{}{
	"audio":                 {},
	"best_of":               {},
	"cache_control":         {},
	"frequency_penalty":     {},
	"logit_bias":            {},
	"logprobs":              {},
	"max_completion_tokens": {},
	"max_output_tokens":     {},
	"max_tokens":            {},
	"metadata":              {},
	"modalities":            {},
	"n":                     {},
	"parallel_tool_calls":   {},
	"presence_penalty":      {},
	"reasoning":             {},
	"response_format":       {},
	"seed":                  {},
	"service_tier":          {},
	"stop":                  {},
	"store":                 {},
	"stream":                {},
	"stream_options":        {},
	"temperature":           {},
	"tool_choice":           {},
	"tools":                 {},
	"top_k":                 {},
	"top_logprobs":          {},
	"top_p":                 {},
	"user":                  {},
}

var usageSensitiveKeys = map[string]struct{}{
	"access_token":        {},
	"api_key":             {},
	"authorization":       {},
	"bearer":              {},
	"client_secret":       {},
	"credential":          {},
	"credentials":         {},
	"key":                 {},
	"password":            {},
	"proxy":               {},
	"refresh_token":       {},
	"secret":              {},
	"session":             {},
	"session_token":       {},
	"token":               {},
	"upstream_api_key":    {},
	"x_api_key":           {},
	"x_goog_api_key":      {},
	"x_stainless_api_key": {},
}

type usageSensitiveTextPattern struct {
	regexp      *regexp.Regexp
	replacement string
}

var usageSensitiveTextPatterns = []usageSensitiveTextPattern{
	{regexp: regexp.MustCompile(`(?i)\bsk-ant-[a-z0-9_-]{8,}\b`), replacement: "[REDACTED]"},
	{regexp: regexp.MustCompile(`(?i)\bsk-[a-z0-9][a-z0-9_-]{8,}\b`), replacement: "[REDACTED]"},
	{regexp: regexp.MustCompile(`(?i)\bai[a-z0-9_-]{24,}\b`), replacement: "[REDACTED]"},
	{regexp: regexp.MustCompile(`(?i)(bearer\s+)[a-z0-9._~+/=-]{12,}`), replacement: "${1}[REDACTED]"},
}

type UsageCallSnapshot struct {
	Content   string `json:"content"`
	Truncated bool   `json:"truncated"`
}

type usageCallSnapshotCollector struct {
	buffer    bytes.Buffer
	truncated bool
}

func BuildUsageRequestSnapshot(raw []byte) *UsageCallSnapshot {
	return buildUsageCallSnapshot(raw, true)
}

func BuildUsageResponseSnapshot(raw []byte) *UsageCallSnapshot {
	return buildUsageCallSnapshot(raw, false)
}

func coalesceUsageCallSnapshot(primary, fallback *UsageCallSnapshot) *UsageCallSnapshot {
	if primary != nil {
		return primary
	}
	return fallback
}

func newUsageCallSnapshotCollector() *usageCallSnapshotCollector {
	return &usageCallSnapshotCollector{}
}

func (c *usageCallSnapshotCollector) AppendString(content string) {
	if c == nil || content == "" {
		return
	}
	c.AppendBytes([]byte(content))
}

func (c *usageCallSnapshotCollector) AppendBytes(content []byte) {
	if c == nil || len(content) == 0 {
		return
	}
	remaining := maxUsageCallSnapshotBytes - c.buffer.Len()
	if remaining <= 0 {
		c.truncated = true
		return
	}
	if len(content) > remaining {
		_, _ = c.buffer.Write(content[:remaining])
		c.truncated = true
		return
	}
	_, _ = c.buffer.Write(content)
}

func (c *usageCallSnapshotCollector) Snapshot() *UsageCallSnapshot {
	if c == nil || c.buffer.Len() == 0 {
		return nil
	}
	snapshot := BuildUsageResponseSnapshot(c.buffer.Bytes())
	if snapshot != nil && c.truncated {
		snapshot.Truncated = true
	}
	return snapshot
}

func buildUsageCallSnapshot(raw []byte, dropRequestParameters bool) *UsageCallSnapshot {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return nil
	}

	content := snapshotContent(raw, dropRequestParameters)
	content, truncated := truncateUsageCallSnapshot(content)
	return &UsageCallSnapshot{
		Content:   content,
		Truncated: truncated,
	}
}

func snapshotContent(raw []byte, dropRequestParameters bool) string {
	var value any
	if err := json.Unmarshal(raw, &value); err == nil {
		value = sanitizeUsageSnapshotValue(value, dropRequestParameters)
		if payload, err := json.MarshalIndent(value, "", "  "); err == nil {
			return redactUsageSnapshotText(string(payload))
		}
	}
	return redactUsageSnapshotText(string(raw))
}

func sanitizeUsageSnapshotValue(value any, dropRequestParameters bool) any {
	switch typed := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(typed))
		for key, child := range typed {
			normalizedKey := normalizeUsageSnapshotKey(key)
			if _, ok := usageSensitiveKeys[normalizedKey]; ok {
				out[key] = "[REDACTED]"
				continue
			}
			if dropRequestParameters {
				if _, ok := usageRequestParameterKeys[normalizedKey]; ok {
					continue
				}
			}
			out[key] = sanitizeUsageSnapshotValue(child, dropRequestParameters)
		}
		return out
	case []any:
		for idx, child := range typed {
			typed[idx] = sanitizeUsageSnapshotValue(child, dropRequestParameters)
		}
		return typed
	default:
		return typed
	}
}

func normalizeUsageSnapshotKey(key string) string {
	key = strings.TrimSpace(strings.ToLower(key))
	key = strings.ReplaceAll(key, "-", "_")
	return key
}

func truncateUsageCallSnapshot(content string) (string, bool) {
	if len(content) <= maxUsageCallSnapshotBytes {
		return content, false
	}
	return content[:maxUsageCallSnapshotBytes], true
}

func redactUsageSnapshotText(content string) string {
	for _, pattern := range usageSensitiveTextPatterns {
		content = pattern.regexp.ReplaceAllString(content, pattern.replacement)
	}
	return content
}
