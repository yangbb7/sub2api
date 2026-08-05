package handler

import "github.com/gin-gonic/gin"

// openAIResponsesSafePreOutputReplay remains disabled until the gateway has a
// durable cross-account idempotency contract for streamed Responses requests.
//
// A client-supplied Idempotency-Key is not enough: it is neither persisted by
// this HTTP streaming path nor documented to deduplicate work across distinct
// upstream account credentials. Replaying after response headers or a first
// output timeout could therefore create a second billable upstream response.
// The governance plan gives the sole account the full 10-second budget instead.
func openAIResponsesSafePreOutputReplay(_ *gin.Context, _ []byte) bool {
	return false
}
