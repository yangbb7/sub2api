package migrations

import (
	"strings"
	"testing"
)

func TestOpsAlertNoiseGovernanceMigration(t *testing.T) {
	content, err := FS.ReadFile("222_ops_alert_noise_governance.sql")
	if err != nil {
		t.Fatalf("read migration: %v", err)
	}

	sql := string(content)
	for _, required := range []string{
		`"min_sla_requests":200`,
		`"min_sla_errors":10`,
		`threshold = 25.0`,
		`'rate_limit_per_hour', 2`,
		`status = 'manual_resolved'`,
	} {
		if !strings.Contains(sql, required) {
			t.Fatalf("migration missing %q", required)
		}
	}
}
