package service

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newCodexModelsTestAccount() *Account {
	return &Account{
		ID:       1,
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
		Credentials: map[string]any{
			"access_token":       "test-access-token",
			"chatgpt_account_id": "acc-123",
		},
	}
}

func TestFetchCodexModelsManifestPassthrough(t *testing.T) {
	manifestBody := `{"models":[{"slug":"gpt-5.5","display_name":"GPT-5.5"}]}`

	var gotAuth, gotAccountID, gotOriginator, gotClientVersion string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotAccountID = r.Header.Get("chatgpt-account-id")
		gotOriginator = r.Header.Get("Originator")
		gotClientVersion = r.URL.Query().Get("client_version")
		w.Header().Set("ETag", `W/"abc123"`)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(manifestBody))
	}))
	defer server.Close()

	original := chatgptCodexModelsURL
	chatgptCodexModelsURL = server.URL
	defer func() { chatgptCodexModelsURL = original }()

	s := &OpenAIGatewayService{}
	manifest, err := s.FetchCodexModelsManifest(context.Background(), newCodexModelsTestAccount(), "0.137.0", "")
	if err != nil {
		t.Fatalf("FetchCodexModelsManifest returned error: %v", err)
	}

	if string(manifest.Body) != manifestBody {
		t.Errorf("body not passed through verbatim: got %q", manifest.Body)
	}
	if manifest.ETag != `W/"abc123"` {
		t.Errorf("etag not passed through: got %q", manifest.ETag)
	}
	if gotAuth != "Bearer test-access-token" {
		t.Errorf("authorization header: got %q", gotAuth)
	}
	if gotAccountID != "acc-123" {
		t.Errorf("chatgpt-account-id header: got %q", gotAccountID)
	}
	if gotOriginator != "codex_cli_rs" {
		t.Errorf("originator header: got %q", gotOriginator)
	}
	if gotClientVersion != "0.137.0" {
		t.Errorf("client_version query: got %q", gotClientVersion)
	}
}

func TestFetchCodexModelsManifestDefaultClientVersion(t *testing.T) {
	var gotClientVersion string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotClientVersion = r.URL.Query().Get("client_version")
		_, _ = w.Write([]byte(`{"models":[]}`))
	}))
	defer server.Close()

	original := chatgptCodexModelsURL
	chatgptCodexModelsURL = server.URL
	defer func() { chatgptCodexModelsURL = original }()

	s := &OpenAIGatewayService{}
	if _, err := s.FetchCodexModelsManifest(context.Background(), newCodexModelsTestAccount(), "", ""); err != nil {
		t.Fatalf("FetchCodexModelsManifest returned error: %v", err)
	}
	if gotClientVersion != openAICodexProbeVersion {
		t.Errorf("default client_version: got %q, want %q", gotClientVersion, openAICodexProbeVersion)
	}
}

func TestFetchCodexModelsManifestNotModified(t *testing.T) {
	var gotIfNoneMatch string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotIfNoneMatch = r.Header.Get("If-None-Match")
		w.Header().Set("ETag", `W/"abc123"`)
		w.WriteHeader(http.StatusNotModified)
	}))
	defer server.Close()

	original := chatgptCodexModelsURL
	chatgptCodexModelsURL = server.URL
	defer func() { chatgptCodexModelsURL = original }()

	s := &OpenAIGatewayService{}
	manifest, err := s.FetchCodexModelsManifest(context.Background(), newCodexModelsTestAccount(), "0.137.0", `W/"abc123"`)
	if err != nil {
		t.Fatalf("FetchCodexModelsManifest returned error: %v", err)
	}
	if !manifest.NotModified {
		t.Error("expected NotModified to be true")
	}
	if gotIfNoneMatch != `W/"abc123"` {
		t.Errorf("if-none-match header: got %q", gotIfNoneMatch)
	}
}

func TestFetchCodexModelsManifestUpstreamError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"detail":"boom"}`, http.StatusInternalServerError)
	}))
	defer server.Close()

	original := chatgptCodexModelsURL
	chatgptCodexModelsURL = server.URL
	defer func() { chatgptCodexModelsURL = original }()

	s := &OpenAIGatewayService{}
	if _, err := s.FetchCodexModelsManifest(context.Background(), newCodexModelsTestAccount(), "0.137.0", ""); err == nil {
		t.Fatal("expected error for upstream 500, got nil")
	}
}

func TestFetchCodexModelsManifestMissingToken(t *testing.T) {
	account := newCodexModelsTestAccount()
	delete(account.Credentials, "access_token")

	s := &OpenAIGatewayService{}
	if _, err := s.FetchCodexModelsManifest(context.Background(), account, "0.137.0", ""); err == nil {
		t.Fatal("expected error for missing access token, got nil")
	}
}

func TestApplyCodexModelsListConfigFiltersAndSynthesizesModels(t *testing.T) {
	manifest := &CodexModelsManifest{
		Body: []byte(`{"models":[{"slug":"gpt-5.5","display_name":"GPT-5.5","tier":"upstream"},{"slug":"gpt-5.4","display_name":"GPT-5.4"}],"other":"kept"}`),
		ETag: `W/"upstream"`,
	}

	ApplyCodexModelsListConfig(manifest, GroupModelsListConfig{
		Enabled: true,
		Models:  []string{"gpt-5.6-sol", "gpt-5.5", "gpt-5.6-terra"},
	})

	if manifest.ETag != "" {
		t.Fatalf("expected transformed manifest to clear upstream etag, got %q", manifest.ETag)
	}

	var got struct {
		Other  string `json:"other"`
		Models []struct {
			Slug        string `json:"slug"`
			ID          string `json:"id"`
			DisplayName string `json:"display_name"`
			Tier        string `json:"tier"`
		} `json:"models"`
	}
	if err := json.Unmarshal(manifest.Body, &got); err != nil {
		t.Fatalf("transformed manifest is invalid JSON: %v", err)
	}

	if got.Other != "kept" {
		t.Fatalf("expected non-model manifest fields to be preserved, got %q", got.Other)
	}
	if len(got.Models) != 3 {
		t.Fatalf("expected 3 models, got %d", len(got.Models))
	}
	if got.Models[0].Slug != "gpt-5.6-sol" || got.Models[0].ID != "gpt-5.6-sol" || got.Models[0].DisplayName != "GPT-5.6 Sol" {
		t.Fatalf("unexpected synthesized first model: %+v", got.Models[0])
	}
	if got.Models[1].Slug != "gpt-5.5" || got.Models[1].Tier != "upstream" {
		t.Fatalf("expected existing upstream model object to be reused, got %+v", got.Models[1])
	}
	if got.Models[2].Slug != "gpt-5.6-terra" || got.Models[2].DisplayName != "GPT-5.6 Terra" {
		t.Fatalf("unexpected synthesized third model: %+v", got.Models[2])
	}
}

func TestApplyCodexModelsListConfigDisabledKeepsManifestUntouched(t *testing.T) {
	body := []byte(`{"models":[{"slug":"gpt-5.5"}]}`)
	manifest := &CodexModelsManifest{Body: body, ETag: `W/"upstream"`}

	ApplyCodexModelsListConfig(manifest, GroupModelsListConfig{
		Enabled: false,
		Models:  []string{"gpt-5.6-sol"},
	})

	if string(manifest.Body) != string(body) {
		t.Fatalf("expected manifest body to remain untouched, got %s", manifest.Body)
	}
	if manifest.ETag != `W/"upstream"` {
		t.Fatalf("expected upstream etag to remain untouched, got %q", manifest.ETag)
	}
}
