package handler

import (
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"
)

func TestCodexModelsIfNoneMatchClearedForCustomModelsList(t *testing.T) {
	apiKey := &service.APIKey{
		Group: &service.Group{
			ModelsListConfig: service.GroupModelsListConfig{
				Enabled: true,
				Models:  []string{"gpt-5.6-sol"},
			},
		},
	}

	if got := codexModelsIfNoneMatch(apiKey, `W/"upstream"`); got != "" {
		t.Fatalf("expected custom Codex model list to bypass upstream etag, got %q", got)
	}
}

func TestCodexModelsIfNoneMatchKeptWithoutCustomModelsList(t *testing.T) {
	apiKey := &service.APIKey{
		Group: &service.Group{
			ModelsListConfig: service.GroupModelsListConfig{
				Enabled: false,
				Models:  []string{"gpt-5.6-sol"},
			},
		},
	}

	if got := codexModelsIfNoneMatch(apiKey, `W/"upstream"`); got != `W/"upstream"` {
		t.Fatalf("expected upstream etag to be preserved, got %q", got)
	}
}
