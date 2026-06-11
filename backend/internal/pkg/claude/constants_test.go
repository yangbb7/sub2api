package claude

import "testing"

func TestNormalizeDisplayModelID(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{"opus display alias", "claude-opus-4.7", "claude-opus-4-7"},
		{"opus thinking display alias", "claude-opus-4.5-thinking", "claude-opus-4-5-thinking"},
		{"sonnet display alias", "claude-sonnet-4.6", "claude-sonnet-4-6"},
		{"haiku display alias", "claude-haiku-4.5", "claude-haiku-4-5"},
		{"trims whitespace", " claude-opus-4.7 ", "claude-opus-4-7"},
		{"canonical unchanged", "claude-opus-4-7", "claude-opus-4-7"},
		{"unknown unchanged", "claude-future-9.9", "claude-future-9.9"},
		{"empty remains empty", "", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := NormalizeDisplayModelID(tt.input); got != tt.expected {
				t.Fatalf("NormalizeDisplayModelID(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

func TestNormalizeDisplayModelID_DoesNotUseOAuthOverrides(t *testing.T) {
	if got := NormalizeDisplayModelID("claude-sonnet-4-5"); got != "claude-sonnet-4-5" {
		t.Fatalf("NormalizeDisplayModelID must not apply OAuth dated override, got %q", got)
	}
}
