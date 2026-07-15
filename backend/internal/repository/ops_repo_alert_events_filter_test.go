package repository

import (
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestBuildOpsAlertEventsWhere_FiltersByRuleIDBeforeLimit(t *testing.T) {
	ruleID := int64(7)
	userID := int64(2)

	where, args := buildOpsAlertEventsWhere(&service.OpsAlertEventFilter{
		RuleID: &ruleID,
		UserID: &userID,
	})

	require.Contains(t, where, "rule_id = $1")
	require.Contains(t, where, "(dimensions->>'user_id') = $2")
	require.Equal(t, []any{int64(7), "2"}, args)
}
