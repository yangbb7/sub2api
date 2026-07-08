package handler

import (
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

func reportOpenAIForwardErrorScheduleResult(gatewayService *service.OpenAIGatewayService, accountID int64, result *service.OpenAIForwardResult, c *gin.Context, err error) {
	if gatewayService == nil {
		return
	}
	if err != nil && service.IsOpenAIContextWindowError(err.Error(), nil) {
		service.MarkOpsContextWindowExceeded(c)
		if result != nil {
			gatewayService.ReportOpenAIAccountScheduleResult(accountID, true, result.FirstTokenMs)
			return
		}
		gatewayService.ReportOpenAIAccountScheduleResult(accountID, true, nil)
		return
	}
	gatewayService.ReportOpenAIAccountScheduleResult(accountID, false, nil)
}
