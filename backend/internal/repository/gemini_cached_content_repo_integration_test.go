//go:build integration

package repository

import (
	"context"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestGeminiCachedContentRepository_Lifecycle(t *testing.T) {
	ctx := context.Background()
	tx := testTx(t)
	repo := &geminiCachedContentRepository{sql: tx}
	now := time.Now().UTC().Truncate(time.Microsecond)
	suffix := time.Now().Format("150405.000000")
	apiKeyID := int64(910001)

	newRecord := func(publicID string, keyID, groupID int64, expire time.Time) *service.GeminiCachedContent {
		return &service.GeminiCachedContent{
			PublicID: publicID + suffix, UserID: 1, APIKeyID: keyID, GroupID: groupID, AccountID: 99,
			UpstreamName: "cachedContents/up" + publicID, Model: "gemini-3.8-flash", UpstreamModel: "models/gemini-3.8-flash",
			DisplayName: "label", TotalTokenCount: 2730, ExpireTime: expire,
			ChannelUsage: service.ChannelUsageFields{ChannelID: 7, OriginalModel: "gemini-pro", ChannelMappedModel: "gemini-3.8-flash", BillingModelSource: "requested"},
		}
	}
	first := newRecord("a", apiKeyID, 42, now.Add(time.Hour))
	require.NoError(t, repo.Create(ctx, first))
	require.Positive(t, first.ID)
	require.False(t, first.CreatedAt.IsZero())
	_, err := tx.ExecContext(ctx, `SAVEPOINT gemini_cached_content_duplicate`)
	require.NoError(t, err)
	require.ErrorIs(t, repo.Create(ctx, newRecord("a", apiKeyID, 42, now.Add(time.Hour))), service.ErrGeminiCachedContentExists)
	_, err = tx.ExecContext(ctx, `ROLLBACK TO SAVEPOINT gemini_cached_content_duplicate`)
	require.NoError(t, err)

	second := newRecord("b", apiKeyID, 42, now.Add(time.Hour))
	require.NoError(t, repo.Create(ctx, second))
	require.NoError(t, repo.Create(ctx, newRecord("expired", apiKeyID, 42, now.Add(-time.Minute))))
	require.NoError(t, repo.Create(ctx, newRecord("othergroup", apiKeyID, 43, now.Add(time.Hour))))
	require.NoError(t, repo.Create(ctx, newRecord("otherkey", apiKeyID+1, 42, now.Add(time.Hour))))

	got, err := repo.GetForOwner(ctx, apiKeyID, first.PublicID)
	require.NoError(t, err)
	require.Equal(t, "cachedContents/upa", got.UpstreamName)
	require.Equal(t, int64(2730), got.TotalTokenCount)
	require.True(t, got.ExpireTime.Equal(first.ExpireTime))
	require.Equal(t, first.ChannelUsage, got.ChannelUsage, "创建时的渠道计费口径随记录持久化")
	_, err = repo.GetForOwner(ctx, apiKeyID+1, first.PublicID)
	require.ErrorIs(t, err, service.ErrGeminiCachedContentNotFound)

	list, err := repo.ListForOwner(ctx, apiKeyID, 42, now, 0, 10)
	require.NoError(t, err)
	require.Len(t, list, 2)
	require.Equal(t, second.PublicID, list[0].PublicID)
	page, err := repo.ListForOwner(ctx, apiKeyID, 42, now, list[0].ID, 10)
	require.NoError(t, err)
	require.Len(t, page, 1)
	require.Equal(t, first.PublicID, page[0].PublicID)

	lease := 2 * time.Minute
	acquired, err := repo.BeginMutation(ctx, first.ID, first.ExpireTime, "t1", lease)
	require.NoError(t, err)
	require.True(t, acquired)
	acquired, err = repo.BeginMutation(ctx, first.ID, first.ExpireTime, "t2", lease)
	require.NoError(t, err)
	require.False(t, acquired, "有进行中的修改时不能再登记")
	taken, err := repo.TakeOverStaleMutation(ctx, first.ID, "t2", lease)
	require.NoError(t, err)
	require.Nil(t, taken, "租约未过期不能接管")
	require.ErrorIs(t, repo.CommitMutation(ctx, first.ID, "t2", now), service.ErrGeminiCachedContentMutationConflict)

	newExpire := now.Add(3 * time.Hour)
	require.NoError(t, repo.CommitMutation(ctx, first.ID, "t1", newExpire))
	got, err = repo.GetForOwner(ctx, apiKeyID, first.PublicID)
	require.NoError(t, err)
	require.True(t, got.ExpireTime.Equal(newExpire))
	require.ErrorIs(t, repo.CommitMutation(ctx, first.ID, "t1", now), service.ErrGeminiCachedContentMutationConflict, "提交后修改意图已清除")

	acquired, err = repo.BeginMutation(ctx, first.ID, first.ExpireTime, "t3", lease)
	require.NoError(t, err)
	require.False(t, acquired, "到期时间已被其他修改改变")
	acquired, err = repo.BeginMutation(ctx, first.ID, newExpire, "t3", lease)
	require.NoError(t, err)
	require.True(t, acquired)
	stale, err := repo.ListStaleMutations(ctx, 10)
	require.NoError(t, err)
	require.NotContains(t, stale, first.ID)

	_, err = tx.ExecContext(ctx, `UPDATE gemini_cached_contents SET mutation_lease_until = NOW() - INTERVAL '1 second' WHERE id = $1`, first.ID)
	require.NoError(t, err)
	stale, err = repo.ListStaleMutations(ctx, 10)
	require.NoError(t, err)
	require.Contains(t, stale, first.ID)
	taken, err = repo.TakeOverStaleMutation(ctx, first.ID, "t4", lease)
	require.NoError(t, err)
	require.NotNil(t, taken)
	require.True(t, taken.ExpireTime.Equal(newExpire), "接管返回修改前的到期时间")
	require.ErrorIs(t, repo.CommitMutation(ctx, first.ID, "t3", now), service.ErrGeminiCachedContentMutationConflict, "被接管后原持有者不能提交")
	require.NoError(t, repo.ReleaseMutation(ctx, first.ID, "t3"))
	acquired, err = repo.BeginMutation(ctx, first.ID, newExpire, "t5", lease)
	require.NoError(t, err)
	require.False(t, acquired, "原持有者释放不影响接管者")
	require.NoError(t, repo.ReleaseMutation(ctx, first.ID, "t4"))
	stale, err = repo.ListStaleMutations(ctx, 10)
	require.NoError(t, err)
	require.NotContains(t, stale, first.ID)

	require.NoError(t, repo.SoftDelete(ctx, first.ID))
	_, err = repo.GetForOwner(ctx, apiKeyID, first.PublicID)
	require.ErrorIs(t, err, service.ErrGeminiCachedContentNotFound)
	_, err = repo.BeginMutation(ctx, first.ID, newExpire, "t6", lease)
	require.ErrorIs(t, err, service.ErrGeminiCachedContentNotFound)
	list, err = repo.ListForOwner(ctx, apiKeyID, 42, now, 0, 10)
	require.NoError(t, err)
	require.Len(t, list, 1)
}

func TestGeminiCachedContentRepository_PurgeInactive(t *testing.T) {
	ctx := context.Background()
	tx := testTx(t)
	// Isolate the global cleanup query from other integration fixtures.
	_, err := tx.ExecContext(ctx, `CREATE TEMP TABLE gemini_cached_contents (LIKE public.gemini_cached_contents INCLUDING ALL) ON COMMIT DROP`)
	require.NoError(t, err)
	repo := &geminiCachedContentRepository{sql: tx}
	_, err = tx.ExecContext(ctx, `INSERT INTO gemini_cached_contents
 (public_id, user_id, api_key_id, group_id, account_id, upstream_name, model, upstream_model, expire_time, deleted_at, mutation_token, mutation_lease_until)
VALUES
 ('expired', 1, 1, 1, 1, 'a', 'm', 'm', NOW() - INTERVAL '1 hour', NULL, NULL, NULL),
 ('deleted', 1, 1, 1, 1, 'b', 'm', 'm', NOW() + INTERVAL '1 hour', NOW() - INTERVAL '2 hours', NULL, NULL),
 ('active', 1, 1, 1, 1, 'c', 'm', 'm', NOW() + INTERVAL '1 hour', NULL, NULL, NULL),
 ('pending', 1, 1, 1, 1, 'd', 'm', 'm', NOW() - INTERVAL '1 hour', NULL, 'pending', NOW() + INTERVAL '1 minute'),
 ('stale', 1, 1, 1, 1, 'e', 'm', 'm', NOW() - INTERVAL '1 hour', NULL, 'stale', NOW() - INTERVAL '1 minute'),
 ('deleted_pending', 1, 1, 1, 1, 'f', 'm', 'm', NOW() - INTERVAL '1 hour', NOW(), 'deleted_pending', NOW() - INTERVAL '1 minute')`)
	require.NoError(t, err)
	count, err := repo.PurgeInactive(ctx, 1)
	require.NoError(t, err)
	require.EqualValues(t, 1, count)
	var exists bool
	require.NoError(t, tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM gemini_cached_contents WHERE public_id = 'expired')`).Scan(&exists))
	require.True(t, exists, "remaining eligible rows wait for the next batch")
	count, err = repo.PurgeInactive(ctx, 1)
	require.NoError(t, err)
	require.EqualValues(t, 1, count)
	count, err = repo.PurgeInactive(ctx, 1000)
	require.NoError(t, err)
	require.Zero(t, count, "repeat cleanup is idempotent and preserves every mutation token")
	var remaining int
	require.NoError(t, tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM gemini_cached_contents`).Scan(&remaining))
	require.Equal(t, 4, remaining)
	active, err := repo.GetForOwner(ctx, 1, "active")
	require.NoError(t, err)
	require.Equal(t, "active", active.PublicID)
	listed, err := repo.ListForOwner(ctx, 1, 1, time.Now(), 0, 10)
	require.NoError(t, err)
	require.Len(t, listed, 1)
	var staleID int64
	require.NoError(t, tx.QueryRowContext(ctx, `SELECT id FROM gemini_cached_contents WHERE public_id = 'stale'`).Scan(&staleID))
	taken, err := repo.TakeOverStaleMutation(ctx, staleID, "recovery", time.Minute)
	require.NoError(t, err)
	require.NotNil(t, taken, "cleanup must leave stale mutations recoverable")
	require.NoError(t, repo.ReleaseMutation(ctx, staleID, "recovery"))
	count, err = repo.PurgeInactive(ctx, 1000)
	require.NoError(t, err)
	require.EqualValues(t, 1, count, "reconciled expired records become eligible")
}

func TestGeminiCachedContentRepository_PurgeInactiveCapsBatch(t *testing.T) {
	ctx := context.Background()
	tx := testTx(t)
	_, err := tx.ExecContext(ctx, `CREATE TEMP TABLE gemini_cached_contents (LIKE public.gemini_cached_contents INCLUDING ALL) ON COMMIT DROP`)
	require.NoError(t, err)
	_, err = tx.ExecContext(ctx, `INSERT INTO gemini_cached_contents
 (public_id, user_id, api_key_id, group_id, account_id, upstream_name, model, upstream_model, expire_time)
 SELECT 'expired-' || n, 1, 1, 1, 1, 'a', 'm', 'm', NOW() - INTERVAL '1 hour' FROM generate_series(1, 1001) AS n`)
	require.NoError(t, err)
	repo := &geminiCachedContentRepository{sql: tx}
	count, err := repo.PurgeInactive(ctx, 1000000)
	require.NoError(t, err)
	require.EqualValues(t, 1000, count)
	count, err = repo.PurgeInactive(ctx, 0)
	require.NoError(t, err)
	require.EqualValues(t, 1, count)
}
