package service

import (
	"context"
	"testing"
	"time"
)

type updateCacheStub struct{}

func (updateCacheStub) GetUpdateInfo(context.Context) (string, error) {
	return "", context.Canceled
}

func (updateCacheStub) SetUpdateInfo(context.Context, string, time.Duration) error {
	return nil
}

type releaseClientStub struct {
	repo string
}

func (c *releaseClientStub) FetchLatestRelease(ctx context.Context, repo string) (*GitHubRelease, error) {
	c.repo = repo
	return &GitHubRelease{TagName: "v1.2.3", Name: "v1.2.3"}, nil
}

func (c *releaseClientStub) DownloadFile(ctx context.Context, url, dest string, maxSize int64) error {
	return nil
}

func (c *releaseClientStub) FetchChecksumFile(ctx context.Context, url string) ([]byte, error) {
	return nil, nil
}

func TestUpdateServiceFetchesReleasesFromFork(t *testing.T) {
	client := &releaseClientStub{}
	service := NewUpdateService(updateCacheStub{}, client, "1.0.0", "release")

	if _, err := service.CheckUpdate(context.Background(), true); err != nil {
		t.Fatalf("CheckUpdate() error = %v", err)
	}
	if client.repo != "yangbb7/sub2api" {
		t.Fatalf("release repo = %q, want %q", client.repo, "yangbb7/sub2api")
	}
}
