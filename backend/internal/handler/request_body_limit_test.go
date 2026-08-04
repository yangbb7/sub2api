package handler

import (
	"bytes"
	"compress/gzip"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestRequestBodyLimitTooLarge(t *testing.T) {
	gin.SetMode(gin.TestMode)

	limit := int64(16)
	router := gin.New()
	router.Use(middleware.RequestBodyLimit(limit))
	router.POST("/test", func(c *gin.Context) {
		_, err := io.ReadAll(c.Request.Body)
		if err != nil {
			if maxErr, ok := extractMaxBytesError(err); ok {
				c.JSON(http.StatusRequestEntityTooLarge, gin.H{
					"error": buildBodyTooLargeMessage(maxErr.Limit),
				})
				return
			}
			c.JSON(http.StatusBadRequest, gin.H{
				"error": "read_failed",
			})
			return
		}
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})

	payload := bytes.Repeat([]byte("a"), int(limit+1))
	req := httptest.NewRequest(http.MethodPost, "/test", bytes.NewReader(payload))
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	require.Equal(t, http.StatusRequestEntityTooLarge, recorder.Code)
	require.Contains(t, recorder.Body.String(), buildBodyTooLargeMessage(limit))
}

func TestPrepareResponsesRequestBodyLimitRejectsKnownContentLengthBeforeRead(t *testing.T) {
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", bytes.NewReader(bytes.Repeat([]byte("x"), 17)))
	c.Request.ContentLength = 17

	limit, rejected := prepareResponsesRequestBodyLimit(c, &config.Config{Gateway: config.GatewayConfig{
		MaxBodySize:          64,
		ResponsesMaxBodySize: 16,
	}})
	require.Equal(t, int64(16), limit)
	require.True(t, rejected)
}

func TestResponsesRequestBodyLimitBoundsChunkedAndNormalizedBodies(t *testing.T) {
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	body := []byte(`{"input":"` + string(bytes.Repeat([]byte("x"), 32)) + `"}`)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", bytes.NewReader(body))
	c.Request.ContentLength = -1 // Simulate a chunked transfer with no early length.
	cfg := &config.Config{Gateway: config.GatewayConfig{MaxBodySize: 128, ResponsesMaxBodySize: 16}}
	_, rejected := prepareResponsesRequestBodyLimit(c, cfg)
	require.False(t, rejected)

	_, err := readLenientResponsesJSONRequestBodyWithPrealloc(c.Request, cfg)
	var maxErr *http.MaxBytesError
	require.True(t, errors.As(err, &maxErr))
	require.Equal(t, int64(16), maxErr.Limit)
}

func TestResponsesRequestBodyLimitBoundsDecompressedBodies(t *testing.T) {
	gin.SetMode(gin.TestMode)
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	_, err := writer.Write([]byte(`{"input":"` + string(bytes.Repeat([]byte("x"), 256)) + `"}`))
	require.NoError(t, err)
	require.NoError(t, writer.Close())

	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", bytes.NewReader(compressed.Bytes()))
	c.Request.Header.Set("Content-Encoding", "gzip")
	cfg := &config.Config{Gateway: config.GatewayConfig{MaxBodySize: 512, ResponsesMaxBodySize: 64}}
	_, rejected := prepareResponsesRequestBodyLimit(c, cfg)
	require.False(t, rejected, "the compressed wire body is within the budget")

	_, err = readLenientResponsesJSONRequestBodyWithPrealloc(c.Request, cfg)
	var maxErr *http.MaxBytesError
	require.True(t, errors.As(err, &maxErr))
	require.Equal(t, int64(64), maxErr.Limit)
}

func TestResponsesBodyLimitFallsBackToGeneralGatewayLimitWhenDisabled(t *testing.T) {
	cfg := &config.Config{Gateway: config.GatewayConfig{MaxBodySize: 64}}
	require.Equal(t, int64(64), responsesMaxBodySize(cfg))
}
