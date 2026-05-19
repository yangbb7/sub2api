package admin

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestOpsWebSocketSubprotocolsPreferNeutralNameAndKeepLegacyCompatibility(t *testing.T) {
	require.NotEmpty(t, upgrader.Subprotocols)
	require.Equal(t, "gateway-admin", upgrader.Subprotocols[0])
	require.Contains(t, upgrader.Subprotocols, "sub2api-admin")
}
