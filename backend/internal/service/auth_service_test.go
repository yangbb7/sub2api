package service

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"strings"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/stretchr/testify/require"
)

func TestIsReservedEmail_DingTalkDomain(t *testing.T) {
	require.True(t, isReservedEmail("dingtalk-123@dingtalk-connect.invalid"))
	require.True(t, isReservedEmail("DINGTALK-456@DINGTALK-CONNECT.INVALID")) // case-insensitive
	require.False(t, isReservedEmail("real@dingtalk.com"))
}

func TestGenerateTokenRawEpochZeroPreservesLegacyFingerprint(t *testing.T) {
	user := &User{
		ID:           42,
		Email:        " Legacy@Example.COM ",
		PasswordHash: "$2a$10$legacy-password-hash",
		Role:         RoleUser,
		Status:       StatusActive,
		TokenVersion: 0,
	}
	material := strings.ToLower(strings.TrimSpace(user.Email)) + "\n" + user.PasswordHash
	sum := sha256.Sum256([]byte(material))
	legacyFingerprint := int64(binary.BigEndian.Uint64(sum[:8]) & 0x7fffffffffffffff)

	svc := &AuthService{cfg: &config.Config{JWT: config.JWTConfig{Secret: "compat-secret", ExpireHour: 1}}}
	token, err := svc.GenerateToken(context.Background(), user)
	require.NoError(t, err)
	claims, err := svc.ValidateToken(token)
	require.NoError(t, err)
	require.Equal(t, legacyFingerprint, claims.TokenVersion)
}
