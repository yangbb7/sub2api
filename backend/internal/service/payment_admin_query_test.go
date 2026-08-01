package service

import (
	"context"
	"testing"
	"time"

	dbent "github.com/Wei-Shaw/sub2api/ent"
	"github.com/stretchr/testify/require"
)

func TestAdminListOrdersAppliesCombinedFiltersAndCreatedAtRange(t *testing.T) {
	ctx := context.Background()
	client := newPaymentConfigServiceTestClient(t)
	user := createPaymentAdminTestUser(t, ctx, client, "list")
	otherUser := createPaymentAdminTestUser(t, ctx, client, "list-other")
	svc := &PaymentService{entClient: client}

	start := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	end := start.AddDate(0, 0, 1)
	matching := createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{
		User:        user,
		Suffix:      "MATCH-in-range",
		Status:      OrderStatusCompleted,
		OrderType:   "balance",
		PaymentType: "stripe",
		CreatedAt:   start,
	})
	createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{
		User:        user,
		Suffix:      "MATCH-upper-bound",
		Status:      OrderStatusCompleted,
		OrderType:   "balance",
		PaymentType: "stripe",
		CreatedAt:   end,
	})
	createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{
		User:        user,
		Suffix:      "MATCH-wrong-status",
		Status:      OrderStatusPending,
		OrderType:   "balance",
		PaymentType: "stripe",
		CreatedAt:   start.Add(time.Hour),
	})
	createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{
		User:        otherUser,
		Suffix:      "MATCH-wrong-user",
		Status:      OrderStatusCompleted,
		OrderType:   "balance",
		PaymentType: "stripe",
		CreatedAt:   start.Add(time.Hour),
	})

	orders, total, err := svc.AdminListOrders(ctx, user.ID, OrderListParams{
		Page:        1,
		PageSize:    20,
		Status:      OrderStatusCompleted,
		OrderType:   "balance",
		PaymentType: "stripe",
		Keyword:     "match",
		StartTime:   &start,
		EndTime:     &end,
	})
	require.NoError(t, err)
	require.Equal(t, 1, total)
	require.Len(t, orders, 1)
	require.Equal(t, matching.ID, orders[0].ID)
}

func TestIterateAdminOrdersUsesStableCreatedAtAndIDCursor(t *testing.T) {
	ctx := context.Background()
	client := newPaymentConfigServiceTestClient(t)
	user := createPaymentAdminTestUser(t, ctx, client, "cursor")
	svc := &PaymentService{entClient: client}

	createdAt := time.Date(2026, 7, 2, 12, 0, 0, 0, time.UTC)
	first := createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{User: user, Suffix: "cursor-1", CreatedAt: createdAt})
	second := createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{User: user, Suffix: "cursor-2", CreatedAt: createdAt})
	third := createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{User: user, Suffix: "cursor-3", CreatedAt: createdAt})
	older := createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{User: user, Suffix: "cursor-older", CreatedAt: createdAt.Add(-time.Second)})

	var got []int64
	err := svc.IterateAdminOrders(ctx, user.ID, OrderListParams{}, 2, func(orders []*dbent.PaymentOrder) error {
		for _, order := range orders {
			got = append(got, order.ID)
		}
		return nil
	})
	require.NoError(t, err)
	require.Equal(t, []int64{third.ID, second.ID, first.ID, older.ID}, got)
}

func TestIterateAdminOrdersStopsBeforeWritingWhenContextIsCancelled(t *testing.T) {
	client := newPaymentConfigServiceTestClient(t)
	svc := &PaymentService{entClient: client}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	callbacks := 0
	err := svc.IterateAdminOrders(ctx, 0, OrderListParams{}, 10, func(_ []*dbent.PaymentOrder) error {
		callbacks++
		return nil
	})
	require.ErrorIs(t, err, context.Canceled)
	require.Zero(t, callbacks)
}

func TestGetDashboardStatsUsesPaidRangeAndRequestedTimezone(t *testing.T) {
	ctx := context.Background()
	client := newPaymentConfigServiceTestClient(t)
	user := createPaymentAdminTestUser(t, ctx, client, "dashboard")
	svc := &PaymentService{entClient: client}
	loc, err := time.LoadLocation("Asia/Shanghai")
	require.NoError(t, err)

	start := time.Date(2026, 7, 1, 0, 0, 0, 0, loc)
	end := start.AddDate(0, 0, 2)
	paidTimes := []time.Time{
		start,
		start.Add(23*time.Hour + 59*time.Minute),
		start.AddDate(0, 0, 1),
		end,
	}
	for index, paidAt := range paidTimes {
		createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{
			User:        user,
			Suffix:      "dashboard-paid-" + string(rune('a'+index)),
			Status:      OrderStatusCompleted,
			CreatedAt:   start.Add(time.Hour),
			PaidAt:      &paidAt,
			PayAmount:   float64((index + 1) * 10),
			PaymentType: "stripe",
		})
	}
	createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{
		User:      user,
		Suffix:    "dashboard-pending-in-range",
		Status:    OrderStatusPending,
		CreatedAt: start,
	})
	createPaymentAdminTestOrder(t, ctx, client, paymentAdminTestOrder{
		User:      user,
		Suffix:    "dashboard-pending-upper-bound",
		Status:    OrderStatusPending,
		CreatedAt: end,
	})

	stats, err := svc.GetDashboardStats(ctx, PaymentDateRange{StartTime: start, EndTime: end, Location: loc})
	require.NoError(t, err)
	require.Equal(t, 3, stats.TotalCount)
	require.Equal(t, CurrencyAmounts{"CNY": 60}, stats.TotalAmount)
	require.Equal(t, CurrencyAmounts{"CNY": 20}, stats.AvgAmount)
	require.Equal(t, 1, stats.PendingOrders)
	require.Len(t, stats.DailySeries, 2)
	require.Equal(t, DailyStats{Date: "2026-07-01", Amount: CurrencyAmounts{"CNY": 30}, Count: 2}, stats.DailySeries[0])
	require.Equal(t, DailyStats{Date: "2026-07-02", Amount: CurrencyAmounts{"CNY": 30}, Count: 1}, stats.DailySeries[1])
}

type paymentAdminTestOrder struct {
	User        *dbent.User
	Suffix      string
	Status      string
	OrderType   string
	PaymentType string
	CreatedAt   time.Time
	PaidAt      *time.Time
	PayAmount   float64
}

func createPaymentAdminTestUser(t *testing.T, ctx context.Context, client *dbent.Client, suffix string) *dbent.User {
	t.Helper()
	user, err := client.User.Create().
		SetEmail("payment-admin-" + suffix + "@example.com").
		SetPasswordHash("hash").
		SetUsername("payment-admin-" + suffix).
		Save(ctx)
	require.NoError(t, err)
	return user
}

func createPaymentAdminTestOrder(t *testing.T, ctx context.Context, client *dbent.Client, input paymentAdminTestOrder) *dbent.PaymentOrder {
	t.Helper()
	if input.Status == "" {
		input.Status = OrderStatusCompleted
	}
	if input.OrderType == "" {
		input.OrderType = "balance"
	}
	if input.PaymentType == "" {
		input.PaymentType = "stripe"
	}
	if input.PayAmount == 0 {
		input.PayAmount = 10
	}

	builder := client.PaymentOrder.Create().
		SetUserID(input.User.ID).
		SetUserEmail(input.User.Email).
		SetUserName(input.User.Username).
		SetAmount(input.PayAmount).
		SetPayAmount(input.PayAmount).
		SetFeeRate(0).
		SetRechargeCode("code-" + input.Suffix).
		SetOutTradeNo("trade-" + input.Suffix).
		SetPaymentType(input.PaymentType).
		SetPaymentTradeNo("payment-" + input.Suffix).
		SetOrderType(input.OrderType).
		SetStatus(input.Status).
		SetExpiresAt(input.CreatedAt.Add(time.Hour)).
		SetClientIP("127.0.0.1").
		SetSrcHost("example.test").
		SetCreatedAt(input.CreatedAt)
	if input.PaidAt != nil {
		builder.SetPaidAt(*input.PaidAt)
	}
	order, err := builder.Save(ctx)
	require.NoError(t, err)
	return order
}
