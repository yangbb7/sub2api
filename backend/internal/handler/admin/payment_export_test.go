package admin

import (
	"context"
	"database/sql"
	"encoding/csv"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"entgo.io/ent/dialect"
	entsql "entgo.io/ent/dialect/sql"
	dbent "github.com/Wei-Shaw/sub2api/ent"
	"github.com/Wei-Shaw/sub2api/ent/enttest"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	_ "modernc.org/sqlite"
)

func TestAdminPaymentOrderCSVUsesSafeWhitelistAndFormulaEscaping(t *testing.T) {
	loc, err := time.LoadLocation("Asia/Shanghai")
	require.NoError(t, err)
	createdAt := time.Date(2026, 6, 30, 16, 0, 0, 0, time.UTC)
	refundReason := "-refund formula"
	failedReason := "@failed formula"
	providerID := "provider-1"
	providerKey := "stripe"
	secret := "secret-value"

	order := &dbent.PaymentOrder{
		ID:                 1,
		OutTradeNo:         "=HYPERLINK(\"https://example.test\")",
		UserID:             2,
		UserEmail:          "+formula@example.com",
		UserName:           " \t@formula-user",
		OrderType:          "balance",
		PaymentType:        "stripe",
		PaymentTradeNo:     "trade-1",
		ProviderInstanceID: &providerID,
		ProviderKey:        &providerKey,
		Amount:             10,
		PayAmount:          10,
		Status:             "COMPLETED",
		RefundReason:       &refundReason,
		FailedReason:       &failedReason,
		ExpiresAt:          createdAt.Add(time.Hour),
		CreatedAt:          createdAt,
		UpdatedAt:          createdAt,
		RechargeCode:       secret,
		PayURL:             &secret,
		QrCode:             &secret,
		QrCodeImg:          &secret,
		ProviderSnapshot:   map[string]any{"currency": "USD", "secret": secret},
		ClientIP:           secret,
		SrcURL:             &secret,
	}

	row := adminPaymentOrderCSVRow(order, loc)
	require.Len(t, row, len(adminPaymentExportHeader))
	values := make(map[string]string, len(row))
	for index, name := range adminPaymentExportHeader {
		values[name] = row[index]
	}
	require.Equal(t, "'=HYPERLINK(\"https://example.test\")", values["out_trade_no"])
	require.Equal(t, "'+formula@example.com", values["user_email"])
	require.Equal(t, "' \t@formula-user", values["user_name"])
	require.Equal(t, "'-refund formula", values["refund_reason"])
	require.Equal(t, "'@failed formula", values["failed_reason"])
	require.Equal(t, "2026-07-01T00:00:00+08:00", values["created_at"])

	header := strings.Join(adminPaymentExportHeader, ",")
	for _, excluded := range []string{
		"recharge_code",
		"pay_url",
		"qr_code",
		"qr_code_img",
		"provider_snapshot",
		"client_ip",
		"src_url",
	} {
		require.NotContains(t, header, excluded)
	}
	require.NotContains(t, strings.Join(row, ","), secret)
}

func TestExportOrdersStaticRouteReturnsUTF8CSVHeader(t *testing.T) {
	gin.SetMode(gin.TestMode)
	client := newAdminPaymentExportTestClient(t)
	paymentService := service.NewPaymentService(client, nil, nil, nil, nil, nil, nil, nil, nil)
	h := NewPaymentHandler(paymentService, nil)
	router := gin.New()
	router.GET("/api/v1/admin/payment/orders/export", h.ExportOrders)
	router.GET("/api/v1/admin/payment/orders/:id", h.GetOrderDetail)

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(
		http.MethodGet,
		"/api/v1/admin/payment/orders/export?start_date=2026-07-01&end_date=2026-07-01&timezone=UTC",
		nil,
	)
	request.Header.Set("If-Modified-Since", "Wed, 21 Oct 2099 07:28:00 GMT")
	router.ServeHTTP(recorder, request)

	require.Equal(t, http.StatusOK, recorder.Code)
	require.Equal(t, "text/csv; charset=utf-8", recorder.Header().Get("Content-Type"))
	require.Contains(t, recorder.Header().Get("Content-Disposition"), "payment-orders-20260701-20260701.csv")
	require.Equal(t, "0", recorder.Header().Get("X-Export-Count"))
	require.Equal(t, "private, no-store", recorder.Header().Get("Cache-Control"))
	require.Equal(t, "no-cache", recorder.Header().Get("Pragma"))
	require.Empty(t, recorder.Header().Get("Last-Modified"))
	require.NotEmpty(t, recorder.Header().Get("Content-Length"))
	require.True(t, strings.HasPrefix(recorder.Body.String(), "\ufeffid,"))

	reader := csv.NewReader(strings.NewReader(recorder.Body.String()))
	header, err := reader.Read()
	require.NoError(t, err)
	require.Equal(t, "\ufeffid", header[0])
	require.Len(t, header, len(adminPaymentExportHeader))
}

func TestExportOrdersReturnsMatchingRowsAndCount(t *testing.T) {
	gin.SetMode(gin.TestMode)
	ctx := context.Background()
	client := newAdminPaymentExportTestClient(t)
	user, err := client.User.Create().
		SetEmail("export@example.com").
		SetPasswordHash("hash").
		SetUsername("export-user").
		Save(ctx)
	require.NoError(t, err)

	createdAt := time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)
	order, err := client.PaymentOrder.Create().
		SetUserID(user.ID).
		SetUserEmail(user.Email).
		SetUserName(user.Username).
		SetAmount(12.34).
		SetPayAmount(12.34).
		SetFeeRate(0).
		SetRechargeCode("sensitive-recharge-code").
		SetOutTradeNo("export-trade-1").
		SetPaymentType("stripe").
		SetPaymentTradeNo("provider-trade-1").
		SetOrderType("balance").
		SetStatus(service.OrderStatusCompleted).
		SetExpiresAt(createdAt.Add(time.Hour)).
		SetClientIP("127.0.0.1").
		SetSrcHost("example.test").
		SetCreatedAt(createdAt).
		Save(ctx)
	require.NoError(t, err)

	paymentService := service.NewPaymentService(client, nil, nil, nil, nil, nil, nil, nil, nil)
	router := gin.New()
	router.GET("/api/v1/admin/payment/orders/export", NewPaymentHandler(paymentService, nil).ExportOrders)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(
		recorder,
		httptest.NewRequest(
			http.MethodGet,
			"/api/v1/admin/payment/orders/export?status=COMPLETED&start_date=2026-07-01&end_date=2026-07-01&timezone=UTC",
			nil,
		),
	)

	require.Equal(t, http.StatusOK, recorder.Code)
	require.Equal(t, "1", recorder.Header().Get("X-Export-Count"))
	require.NotContains(t, recorder.Body.String(), "sensitive-recharge-code")
	rows, err := csv.NewReader(strings.NewReader(recorder.Body.String())).ReadAll()
	require.NoError(t, err)
	require.Len(t, rows, 2)
	require.Equal(t, "\ufeffid", rows[0][0])
	require.Equal(t, order.OutTradeNo, rows[1][1])
	require.Equal(t, user.Email, rows[1][3])
}

func TestExportOrdersReturnsJSONErrorBeforeStartingCSVWhenInitialQueryFails(t *testing.T) {
	gin.SetMode(gin.TestMode)
	client := newAdminPaymentExportTestClient(t)
	paymentService := service.NewPaymentService(client, nil, nil, nil, nil, nil, nil, nil, nil)
	h := NewPaymentHandler(paymentService, nil)
	require.NoError(t, client.Close())
	router := gin.New()
	router.GET("/api/v1/admin/payment/orders/export", h.ExportOrders)

	recorder := httptest.NewRecorder()
	router.ServeHTTP(
		recorder,
		httptest.NewRequest(http.MethodGet, "/api/v1/admin/payment/orders/export", nil),
	)

	require.Equal(t, http.StatusInternalServerError, recorder.Code)
	require.Contains(t, recorder.Header().Get("Content-Type"), "application/json")
	require.NotContains(t, recorder.Body.String(), "\ufeffid,")
}

func newAdminPaymentExportTestClient(t *testing.T) *dbent.Client {
	t.Helper()
	db, err := sql.Open("sqlite", "file:admin_payment_export?mode=memory&cache=shared&_fk=1")
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	_, err = db.Exec("PRAGMA foreign_keys = ON")
	require.NoError(t, err)
	driver := entsql.OpenDB(dialect.SQLite, db)
	client := enttest.NewClient(t, enttest.WithOptions(dbent.Driver(driver)))
	t.Cleanup(func() { _ = client.Close() })
	return client
}
