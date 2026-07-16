package admin

import (
	"fmt"
	"strconv"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/timezone"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

const paymentDateLayout = "2006-01-02"

type adminPaymentDateRange struct {
	StartTime *time.Time
	EndTime   *time.Time
	Location  *time.Location
}

// parseAdminPaymentDateRange parses inclusive calendar dates into a half-open
// instant range. defaultDays <= 0 leaves the range unset when no dates are given.
func parseAdminPaymentDateRange(c *gin.Context, defaultDays int) (adminPaymentDateRange, error) {
	loc, err := adminPaymentLocation(c.Query("timezone"))
	if err != nil {
		return adminPaymentDateRange{}, err
	}

	startDate := c.Query("start_date")
	endDate := c.Query("end_date")
	if (startDate == "") != (endDate == "") {
		return adminPaymentDateRange{}, fmt.Errorf("start_date and end_date must be provided together")
	}
	if startDate == "" {
		if defaultDays <= 0 {
			return adminPaymentDateRange{Location: loc}, nil
		}
		now := time.Now().In(loc)
		end := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc).AddDate(0, 0, 1)
		start := end.AddDate(0, 0, -defaultDays)
		return adminPaymentDateRange{StartTime: &start, EndTime: &end, Location: loc}, nil
	}

	start, err := time.ParseInLocation(paymentDateLayout, startDate, loc)
	if err != nil {
		return adminPaymentDateRange{}, fmt.Errorf("invalid start_date format, use YYYY-MM-DD")
	}
	endDateTime, err := time.ParseInLocation(paymentDateLayout, endDate, loc)
	if err != nil {
		return adminPaymentDateRange{}, fmt.Errorf("invalid end_date format, use YYYY-MM-DD")
	}
	if endDateTime.Before(start) {
		return adminPaymentDateRange{}, fmt.Errorf("end_date must be on or after start_date")
	}
	end := endDateTime.AddDate(0, 0, 1)
	return adminPaymentDateRange{StartTime: &start, EndTime: &end, Location: loc}, nil
}

func adminPaymentLocation(name string) (*time.Location, error) {
	if name == "" {
		return timezone.Location(), nil
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return nil, fmt.Errorf("invalid timezone: use a valid IANA timezone name")
	}
	return loc, nil
}

func parseAdminOrderFilters(c *gin.Context) (int64, service.OrderListParams, *time.Location, error) {
	dateRange, err := parseAdminPaymentDateRange(c, 0)
	if err != nil {
		return 0, service.OrderListParams{}, nil, err
	}

	var userID int64
	if rawUserID := c.Query("user_id"); rawUserID != "" {
		parsed, parseErr := strconv.ParseInt(rawUserID, 10, 64)
		if parseErr != nil || parsed <= 0 {
			return 0, service.OrderListParams{}, nil, fmt.Errorf("invalid user_id: use a positive integer")
		}
		userID = parsed
	}

	return userID, service.OrderListParams{
		Status:      c.Query("status"),
		OrderType:   c.Query("order_type"),
		PaymentType: c.Query("payment_type"),
		Keyword:     c.Query("keyword"),
		StartTime:   dateRange.StartTime,
		EndTime:     dateRange.EndTime,
	}, dateRange.Location, nil
}
