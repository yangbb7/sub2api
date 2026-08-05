package service

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestOpsErrorLogStatusPairsRemainIndependentAcrossHeartbeatBoundary(t *testing.T) {
	tests := []struct {
		name           string
		statusCode     *int
		upstreamStatus *int
		wantStatus     any
		wantUpstream   any
	}{
		{
			name:           "pre heartbeat failure preserves gateway status",
			statusCode:     intPtr(502),
			upstreamStatus: intPtr(529),
			wantStatus:     float64(502),
			wantUpstream:   float64(529),
		},
		{
			name:           "post heartbeat failure preserves committed gateway status",
			statusCode:     intPtr(200),
			upstreamStatus: intPtr(529),
			wantStatus:     float64(200),
			wantUpstream:   float64(529),
		},
		{
			name:         "absent statuses remain JSON null for dash rendering",
			wantStatus:   nil,
			wantUpstream: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded, err := json.Marshal(OpsErrorLog{StatusCode: tt.statusCode, UpstreamStatusCode: tt.upstreamStatus})
			require.NoError(t, err)
			var decoded map[string]any
			require.NoError(t, json.Unmarshal(encoded, &decoded))
			require.Equal(t, tt.wantStatus, decoded["status_code"])
			require.Equal(t, tt.wantUpstream, decoded["upstream_status_code"])
		})
	}
}

func TestOpsErrorLogDetailSerializesEmbeddedUpstreamStatusOnce(t *testing.T) {
	statusCode := 200
	upstreamStatusCode := 529
	encoded, err := json.Marshal(OpsErrorLogDetail{OpsErrorLog: OpsErrorLog{
		StatusCode:         &statusCode,
		UpstreamStatusCode: &upstreamStatusCode,
	}})
	require.NoError(t, err)
	var decoded map[string]any
	require.NoError(t, json.Unmarshal(encoded, &decoded))
	require.Equal(t, float64(200), decoded["status_code"])
	require.Equal(t, float64(529), decoded["upstream_status_code"])
}
