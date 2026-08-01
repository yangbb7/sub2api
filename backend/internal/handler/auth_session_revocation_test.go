//go:build unit

package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/config"
	middleware2 "github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestAuthHandlerRevokeAllSessionsInvalidatesAccessTokens(t *testing.T) {
	gin.SetMode(gin.TestMode)

	repo := &userHandlerRepoStub{
		user: &service.User{
			ID:           29,
			Email:        "session@example.com",
			Username:     "session-user",
			Role:         service.RoleUser,
			Status:       service.StatusActive,
			TokenVersion: 7,
		},
	}
	refreshTokenCache := &userHandlerRefreshTokenCacheStub{}
	cfg := &config.Config{
		JWT: config.JWTConfig{
			Secret:                 "test-secret",
			ExpireHour:             1,
			RefreshTokenExpireDays: 7,
		},
	}
	authService := service.NewAuthService(nil, repo, nil, refreshTokenCache, cfg, nil, nil, nil, nil, nil, nil, nil, nil)
	handler := &AuthHandler{authService: authService}
	tokenPair, err := authService.GenerateTokenPair(context.Background(), repo.user, "")
	require.NoError(t, err)
	refreshTokenCache.deleteUserErr = errors.New("redis unavailable")

	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/v1/auth/revoke-all-sessions", nil)
	c.Set(string(middleware2.ContextKeyUser), middleware2.AuthSubject{UserID: 29})

	handler.RevokeAllSessions(c)

	require.Equal(t, http.StatusOK, recorder.Code)
	require.Equal(t, []int64{29}, refreshTokenCache.revokedUserIDs)
	require.Equal(t, int64(8), repo.user.TokenVersion)

	protected := gin.New()
	protected.Use(gin.HandlerFunc(middleware2.NewJWTAuthMiddleware(service.NewAuthService(nil, repo, nil, nil, cfg, nil, nil, nil, nil, nil, nil, nil, nil), service.NewUserService(repo, nil, nil, nil), nil, nil)))
	protected.GET("/protected", func(c *gin.Context) { c.Status(http.StatusNoContent) })
	accessRecorder := httptest.NewRecorder()
	accessRequest := httptest.NewRequest(http.MethodGet, "/protected", nil)
	accessRequest.Header.Set("Authorization", "Bearer "+tokenPair.AccessToken)
	protected.ServeHTTP(accessRecorder, accessRequest)
	require.Equal(t, http.StatusUnauthorized, accessRecorder.Code)
	require.Contains(t, accessRecorder.Body.String(), "TOKEN_REVOKED")

	_, err = authService.RefreshTokenPair(context.Background(), tokenPair.RefreshToken)
	require.ErrorIs(t, err, service.ErrTokenRevoked)

	var resp struct {
		Code int `json:"code"`
		Data struct {
			Message string `json:"message"`
		} `json:"data"`
	}
	require.NoError(t, json.Unmarshal(recorder.Body.Bytes(), &resp))
	require.Equal(t, 0, resp.Code)
	require.Equal(t, "All sessions have been revoked. Please log in again.", resp.Data.Message)
}
