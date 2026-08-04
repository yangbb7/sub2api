package handler

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestOpenAIResponsesSafePreOutputReplay(t *testing.T) {
	gin.SetMode(gin.TestMode)
	newContext := func(key string) *gin.Context {
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", nil)
		if key != "" {
			c.Request.Header.Set("Idempotency-Key", key)
		}
		return c
	}

	require.True(t, openAIResponsesSafePreOutputReplay(newContext("key"), []byte(`{"stream":true,"input":"synthetic"}`)))
	require.False(t, openAIResponsesSafePreOutputReplay(newContext(""), []byte(`{"stream":true}`)))
	require.False(t, openAIResponsesSafePreOutputReplay(newContext("key"), []byte(`{"tools":[{"type":"function","name":"write"}]}`)))
	require.False(t, openAIResponsesSafePreOutputReplay(newContext("key"), []byte(`{"previous_response_id":"resp_1"}`)))
	require.False(t, openAIResponsesSafePreOutputReplay(newContext("key"), []byte(`{"conversation":"conv_1"}`)))
	require.False(t, openAIResponsesSafePreOutputReplay(newContext("key"), []byte(`{"tools":"unexpected"}`)))
}
