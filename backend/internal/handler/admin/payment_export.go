package admin

import (
	"encoding/csv"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode"

	dbent "github.com/Wei-Shaw/sub2api/ent"
	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

const adminPaymentExportBatchSize = 500

var adminPaymentExportHeader = []string{
	"id",
	"out_trade_no",
	"user_id",
	"user_email",
	"user_name",
	"order_type",
	"plan_id",
	"subscription_group_id",
	"subscription_days",
	"payment_type",
	"payment_trade_no",
	"provider_instance_id",
	"provider_key",
	"amount",
	"pay_amount",
	"fee_rate",
	"currency",
	"status",
	"refund_amount",
	"refund_reason",
	"refund_at",
	"refund_requested_at",
	"refund_request_reason",
	"refund_requested_by",
	"expires_at",
	"paid_at",
	"completed_at",
	"failed_at",
	"failed_reason",
	"created_at",
	"updated_at",
}

// ExportOrders writes all matching orders to a temporary CSV before sending it.
// GET /api/v1/admin/payment/orders/export
func (h *PaymentHandler) ExportOrders(c *gin.Context) {
	userID, params, loc, err := parseAdminOrderFilters(c)
	if err != nil {
		response.BadRequest(c, err.Error())
		return
	}

	tempFile, err := os.CreateTemp("", "sub2api-payment-orders-*.csv")
	if err != nil {
		response.InternalError(c, "Failed to export payment orders")
		return
	}
	defer func() {
		_ = tempFile.Close()
		_ = os.Remove(tempFile.Name())
	}()

	writer := csv.NewWriter(tempFile)
	header := append([]string(nil), adminPaymentExportHeader...)
	header[0] = "\ufeff" + header[0]
	if err := writer.Write(header); err != nil {
		response.InternalError(c, "Failed to export payment orders")
		return
	}

	exportCount := 0
	err = h.paymentService.IterateAdminOrders(
		c.Request.Context(),
		userID,
		params,
		adminPaymentExportBatchSize,
		func(orders []*dbent.PaymentOrder) error {
			for _, order := range orders {
				if err := writer.Write(adminPaymentOrderCSVRow(order, loc)); err != nil {
					return fmt.Errorf("write payment order csv: %w", err)
				}
				exportCount++
			}
			writer.Flush()
			if err := writer.Error(); err != nil {
				return fmt.Errorf("flush payment order csv: %w", err)
			}
			return nil
		},
	)
	if err != nil {
		response.InternalError(c, "Failed to export payment orders")
		return
	}
	writer.Flush()
	if err := writer.Error(); err != nil {
		response.InternalError(c, "Failed to export payment orders")
		return
	}
	if err := tempFile.Sync(); err != nil {
		response.InternalError(c, "Failed to export payment orders")
		return
	}
	if _, err := tempFile.Seek(0, io.SeekStart); err != nil {
		response.InternalError(c, "Failed to export payment orders")
		return
	}
	fileInfo, err := tempFile.Stat()
	if err != nil {
		response.InternalError(c, "Failed to export payment orders")
		return
	}

	filename := adminPaymentExportFilename(params, loc)
	c.Header("Content-Type", "text/csv; charset=utf-8")
	c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filename))
	c.Header("X-Export-Count", strconv.Itoa(exportCount))
	c.Header("Content-Length", strconv.FormatInt(fileInfo.Size(), 10))
	c.Header("Cache-Control", "private, no-store")
	c.Header("Pragma", "no-cache")
	c.Status(http.StatusOK)
	if _, err := io.Copy(c.Writer, tempFile); err != nil {
		_ = c.Error(fmt.Errorf("send payment order csv: %w", err))
		c.Abort()
	}
}

func adminPaymentExportFilename(params service.OrderListParams, loc *time.Location) string {
	if params.StartTime != nil && params.EndTime != nil {
		start := params.StartTime.In(loc).Format("20060102")
		end := params.EndTime.In(loc).AddDate(0, 0, -1).Format("20060102")
		return fmt.Sprintf("payment-orders-%s-%s.csv", start, end)
	}
	return fmt.Sprintf("payment-orders-%s.csv", time.Now().In(loc).Format("20060102"))
}

func adminPaymentOrderCSVRow(order *dbent.PaymentOrder, loc *time.Location) []string {
	return []string{
		strconv.FormatInt(order.ID, 10),
		adminPaymentCSVCell(order.OutTradeNo),
		strconv.FormatInt(order.UserID, 10),
		adminPaymentCSVCell(order.UserEmail),
		adminPaymentCSVCell(order.UserName),
		adminPaymentCSVCell(order.OrderType),
		adminPaymentOptionalInt64(order.PlanID),
		adminPaymentOptionalInt64(order.SubscriptionGroupID),
		adminPaymentOptionalInt(order.SubscriptionDays),
		adminPaymentCSVCell(order.PaymentType),
		adminPaymentCSVCell(order.PaymentTradeNo),
		adminPaymentCSVCell(adminPaymentOptionalString(order.ProviderInstanceID)),
		adminPaymentCSVCell(adminPaymentOptionalString(order.ProviderKey)),
		strconv.FormatFloat(order.Amount, 'f', 2, 64),
		strconv.FormatFloat(order.PayAmount, 'f', 2, 64),
		strconv.FormatFloat(order.FeeRate, 'f', 4, 64),
		adminPaymentCSVCell(service.PaymentOrderCurrency(order)),
		adminPaymentCSVCell(order.Status),
		strconv.FormatFloat(order.RefundAmount, 'f', 2, 64),
		adminPaymentCSVCell(adminPaymentOptionalString(order.RefundReason)),
		adminPaymentOptionalTime(order.RefundAt, loc),
		adminPaymentOptionalTime(order.RefundRequestedAt, loc),
		adminPaymentCSVCell(adminPaymentOptionalString(order.RefundRequestReason)),
		adminPaymentCSVCell(adminPaymentOptionalString(order.RefundRequestedBy)),
		adminPaymentTime(order.ExpiresAt, loc),
		adminPaymentOptionalTime(order.PaidAt, loc),
		adminPaymentOptionalTime(order.CompletedAt, loc),
		adminPaymentOptionalTime(order.FailedAt, loc),
		adminPaymentCSVCell(adminPaymentOptionalString(order.FailedReason)),
		adminPaymentTime(order.CreatedAt, loc),
		adminPaymentTime(order.UpdatedAt, loc),
	}
}

func adminPaymentCSVCell(value string) string {
	trimmed := strings.TrimLeftFunc(value, unicode.IsSpace)
	if trimmed == "" {
		return value
	}
	switch trimmed[0] {
	case '=', '+', '-', '@':
		return "'" + value
	default:
		return value
	}
}

func adminPaymentOptionalString(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func adminPaymentOptionalInt64(value *int64) string {
	if value == nil {
		return ""
	}
	return strconv.FormatInt(*value, 10)
}

func adminPaymentOptionalInt(value *int) string {
	if value == nil {
		return ""
	}
	return strconv.Itoa(*value)
}

func adminPaymentTime(value time.Time, loc *time.Location) string {
	return value.In(loc).Format(time.RFC3339)
}

func adminPaymentOptionalTime(value *time.Time, loc *time.Location) string {
	if value == nil {
		return ""
	}
	return adminPaymentTime(*value, loc)
}
