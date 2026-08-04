package handler

import (
	"errors"
	"fmt"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/config"
	pkghttputil "github.com/Wei-Shaw/sub2api/internal/pkg/httputil"
	"github.com/gin-gonic/gin"
)

func extractMaxBytesError(err error) (*http.MaxBytesError, bool) {
	var maxErr *http.MaxBytesError
	if errors.As(err, &maxErr) {
		return maxErr, true
	}
	return nil, false
}

func formatBodyLimit(limit int64) string {
	const mb = 1024 * 1024
	if limit >= mb {
		return fmt.Sprintf("%dMB", limit/mb)
	}
	return fmt.Sprintf("%dB", limit)
}

func buildBodyTooLargeMessage(limit int64) string {
	return fmt.Sprintf("Request body too large, limit is %s", formatBodyLimit(limit))
}

func readLenientJSONRequestBodyWithPrealloc(req *http.Request, cfg *config.Config) ([]byte, error) {
	return pkghttputil.ReadLenientJSONRequestBodyWithPrealloc(req, gatewayMaxBodySize(cfg))
}

// prepareResponsesRequestBodyLimit applies the /v1/responses budget before
// JSON is read or parsed. A zero endpoint-specific setting inherits the
// general gateway limit. Content-Length is checked up front so oversized
// requests fail fast without a large allocation. The MaxBytesReader also
// covers chunked uploads, while the specialized reader applies the same
// ceiling after Content-Encoding decompression and lenient JSON normalization.
func prepareResponsesRequestBodyLimit(c *gin.Context, cfg *config.Config) (limit int64, rejected bool) {
	limit = responsesMaxBodySize(cfg)
	if limit <= 0 || c == nil || c.Request == nil {
		return limit, false
	}
	if c.Request.ContentLength > limit {
		return limit, true
	}
	if c.Request.Body != nil {
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, limit)
	}
	return limit, false
}

func readLenientResponsesJSONRequestBodyWithPrealloc(req *http.Request, cfg *config.Config) ([]byte, error) {
	return pkghttputil.ReadLenientJSONRequestBodyWithPrealloc(req, responsesMaxBodySize(cfg))
}

func gatewayMaxBodySize(cfg *config.Config) int64 {
	if cfg == nil {
		return 0
	}
	return cfg.Gateway.MaxBodySize
}

func responsesMaxBodySize(cfg *config.Config) int64 {
	if cfg == nil || cfg.Gateway.ResponsesMaxBodySize <= 0 {
		return gatewayMaxBodySize(cfg)
	}
	return cfg.Gateway.ResponsesMaxBodySize
}
