//go:build unit

package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type cachedContentRetentionRepo struct {
	*geminiCachedContentRepoStub
	calls int
	err   error
}

func (r *cachedContentRetentionRepo) PurgeInactive(ctx context.Context, limit int) (int64, error) {
	r.calls++
	if limit != 1000 {
		return 0, errors.New("unexpected batch limit")
	}
	deadline, ok := ctx.Deadline()
	if !ok || time.Until(deadline) > time.Minute {
		return 0, errors.New("missing bounded timeout")
	}
	return int64(limit), r.err
}

func TestGeminiCachedContentService_PurgeInactiveBounded(t *testing.T) {
	repo := &cachedContentRetentionRepo{geminiCachedContentRepoStub: newGeminiCachedContentRepoStub()}
	svc := NewGeminiCachedContentService(repo, nil, nil)
	count, err := svc.purgeInactive(context.Background())
	require.NoError(t, err)
	require.EqualValues(t, 1000, count)
	require.Equal(t, 1, repo.calls, "a full batch must not trigger an unbounded drain loop")
	repo.err = errors.New("database unavailable")
	_, err = svc.purgeInactive(context.Background())
	require.ErrorIs(t, err, repo.err)
}
