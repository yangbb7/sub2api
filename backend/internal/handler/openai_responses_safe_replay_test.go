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

	tests := []struct {
		name string
		key  string
		body string
	}{
		{name: "keyed stateless text input", key: "key", body: `{"stream":true,"store":false,"input":"synthetic"}`},
		{name: "keyed stateless message items", key: "key", body: `{"store":false,"input":[{"type":"message","role":"user","content":"hello"}]}`},
		{name: "default stored response", key: "key", body: `{"stream":true,"input":"synthetic"}`},
		{name: "stored response", key: "key", body: `{"stream":true,"store":true,"input":"synthetic"}`},
		{name: "missing key", body: `{"stream":true,"input":"synthetic"}`},
		{name: "tools", key: "key", body: `{"input":"synthetic","tools":[{"type":"function","name":"write"}]}`},
		{name: "empty tools with tool choice", key: "key", body: `{"input":"synthetic","tools":[],"tool_choice":"required"}`},
		{name: "previous response", key: "key", body: `{"input":"synthetic","previous_response_id":"resp_1"}`},
		{name: "conversation", key: "key", body: `{"input":"synthetic","conversation":"conv_1"}`},
		{name: "background", key: "key", body: `{"input":"synthetic","background":true}`},
		{name: "function output item", key: "key", body: `{"input":[{"type":"function_call_output","call_id":"call_1","output":"done"}]}`},
		{name: "malformed tools", key: "key", body: `{"input":"synthetic","tools":"unexpected"}`},
		{name: "missing input", key: "key", body: `{"stream":true}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.False(t, openAIResponsesSafePreOutputReplay(newContext(tt.key), []byte(tt.body)))
		})
	}
}
