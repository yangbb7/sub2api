package migrations

import (
	"strings"
	"testing"
)

func TestOpsAlertSilenceUserScopeMigrationRecoversMissingTable(t *testing.T) {
	content, err := FS.ReadFile("174_add_user_scope_to_ops_alert_silences.sql")
	if err != nil {
		t.Fatalf("read migration: %v", err)
	}

	sql := string(content)
	createAt := strings.Index(sql, "CREATE TABLE IF NOT EXISTS ops_alert_silences")
	alterAt := strings.Index(sql, "ALTER TABLE ops_alert_silences")
	if createAt < 0 || alterAt < 0 || createAt >= alterAt {
		t.Fatalf("migration must create the silences table before altering it")
	}
}
