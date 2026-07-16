package admin

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestParseAdminPaymentDateRangeSingleDayAndTimezone(t *testing.T) {
	c := newAdminPaymentTestContext("/?start_date=2026-03-08&end_date=2026-03-08&timezone=America/New_York")

	dateRange, err := parseAdminPaymentDateRange(c, 0)
	require.NoError(t, err)
	require.NotNil(t, dateRange.StartTime)
	require.NotNil(t, dateRange.EndTime)
	require.Equal(t, "America/New_York", dateRange.Location.String())
	require.Equal(t, "2026-03-08T00:00:00-05:00", dateRange.StartTime.Format(time.RFC3339))
	require.Equal(t, "2026-03-09T00:00:00-04:00", dateRange.EndTime.Format(time.RFC3339))
	require.Equal(t, 23*time.Hour, dateRange.EndTime.Sub(*dateRange.StartTime))
}

func TestParseAdminPaymentDateRangeDefaultDaysUsesWholeCalendarDays(t *testing.T) {
	c := newAdminPaymentTestContext("/?timezone=Asia/Shanghai")

	dateRange, err := parseAdminPaymentDateRange(c, 30)
	require.NoError(t, err)
	require.NotNil(t, dateRange.StartTime)
	require.NotNil(t, dateRange.EndTime)
	require.Equal(t, 0, dateRange.StartTime.Hour())
	require.Equal(t, 0, dateRange.EndTime.Hour())
	require.Equal(t, dateRange.EndTime.AddDate(0, 0, -30), *dateRange.StartTime)
}

func TestParseAdminPaymentDateRangeRejectsInvalidInput(t *testing.T) {
	tests := []struct {
		name  string
		query string
	}{
		{name: "missing end", query: "/?start_date=2026-07-01"},
		{name: "missing start", query: "/?end_date=2026-07-01"},
		{name: "invalid start", query: "/?start_date=2026-02-30&end_date=2026-03-01"},
		{name: "invalid end", query: "/?start_date=2026-03-01&end_date=not-a-date"},
		{name: "reversed", query: "/?start_date=2026-03-02&end_date=2026-03-01"},
		{name: "invalid timezone", query: "/?start_date=2026-03-01&end_date=2026-03-01&timezone=Mars/Olympus"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := parseAdminPaymentDateRange(newAdminPaymentTestContext(tt.query), 0)
			require.Error(t, err)
		})
	}
}

func TestAdminPaymentReadHandlersReturnBadRequestForInvalidFilters(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := &PaymentHandler{}
	router := gin.New()
	router.GET("/orders", h.ListOrders)
	router.GET("/orders/export", h.ExportOrders)
	router.GET("/dashboard", h.GetDashboard)

	for _, path := range []string{
		"/orders?start_date=2026-07-01",
		"/orders?start_date=2026-07-02&end_date=2026-07-01",
		"/orders?user_id=abc",
		"/orders?user_id=0",
		"/orders/export?user_id=-1",
		"/dashboard?start_date=bad&end_date=2026-07-01",
		"/dashboard?start_date=2026-07-01&end_date=2026-07-01&timezone=Bad/Timezone",
	} {
		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		require.Equal(t, http.StatusBadRequest, recorder.Code, path)
	}
}

func newAdminPaymentTestContext(target string) *gin.Context {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodGet, target, nil)
	return c
}
