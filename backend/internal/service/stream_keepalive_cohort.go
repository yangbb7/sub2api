package service

import (
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/gin-gonic/gin"
)

const responsesStreamKeepaliveCohortContextKey = "responses_stream_keepalive_cohort"

// ConfigureResponsesStreamKeepaliveCohort records whether /responses SSE
// keepalives are configured. Keepalives are independent from the first-output
// budget rollout: they start only after upstream headers, but must remain
// available while that rollout is set to 0 for observation or rollback.
func ConfigureResponsesStreamKeepaliveCohort(c *gin.Context, cfg *config.Config) {
	if c == nil {
		return
	}
	enabled := false
	if c.Request != nil && cfg != nil && cfg.Gateway.StreamKeepaliveInterval > 0 {
		enabled = true
	}
	c.Set(responsesStreamKeepaliveCohortContextKey, enabled)
}

func responsesStreamKeepaliveCohortEnabled(c *gin.Context) bool {
	if c == nil {
		return true
	}
	v, marked := c.Get(responsesStreamKeepaliveCohortContextKey)
	if !marked {
		return true
	}
	enabled, ok := v.(bool)
	return ok && enabled
}

func responsesStreamKeepaliveInterval(c *gin.Context, cfg *config.Config) time.Duration {
	if !responsesStreamKeepaliveCohortEnabled(c) || cfg == nil || cfg.Gateway.StreamKeepaliveInterval <= 0 {
		return 0
	}
	return time.Duration(cfg.Gateway.StreamKeepaliveInterval) * time.Second
}
