package handler

import (
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/tidwall/gjson"
)

// openAIResponsesSafePreOutputReplay is deliberately conservative. Before a
// response has reached the client we may switch accounts only for stateless
// requests protected by a caller-supplied idempotency key. Tools and response
// continuation can perform or depend on stateful work, so they never replay
// across accounts.
func openAIResponsesSafePreOutputReplay(c *gin.Context, body []byte) bool {
	if c == nil || c.Request == nil || strings.TrimSpace(c.GetHeader("Idempotency-Key")) == "" {
		return false
	}
	if gjson.GetBytes(body, "previous_response_id").Exists() {
		return false
	}
	// conversation is another Responses state-continuation surface. Even if a
	// provider currently treats it as advisory, replaying it across accounts
	// could bind a request to a different persisted state.
	if gjson.GetBytes(body, "conversation").Exists() {
		return false
	}
	tools := gjson.GetBytes(body, "tools")
	if tools.Exists() && tools.IsArray() && len(tools.Array()) > 0 {
		return false
	}
	// Refuse unknown non-array tool shapes as well. A malformed request should
	// be rejected by upstream once, not replayed against another account.
	return !tools.Exists() || tools.IsArray()
}
