package provider

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/google/uuid"
)

func TestCoinbaseCreatePaymentCreatesHostedCheckout(t *testing.T) {
	var gotBody coinbaseCreateCheckoutRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/checkouts" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); !strings.HasPrefix(got, "Bearer ") {
			t.Fatalf("Authorization = %q, want bearer JWT", got)
		}
		idempotencyKey, err := uuid.Parse(r.Header.Get("X-Idempotency-Key"))
		if err != nil || idempotencyKey.Version() != 4 {
			t.Fatalf("X-Idempotency-Key = %q, want UUID v4", r.Header.Get("X-Idempotency-Key"))
		}
		if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
			t.Fatalf("decode request body: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chk_123","url":"https://payments.coinbase.com/payment-links/pl_123","amount":"12.34","currency":"USDC","status":"ACTIVE"}`))
	}))
	defer server.Close()

	prov, err := NewCoinbase("1", testCoinbaseConfig(t, server.URL, "USDC"))
	if err != nil {
		t.Fatalf("NewCoinbase returned error: %v", err)
	}
	resp, err := prov.CreatePayment(context.Background(), payment.CreatePaymentRequest{
		OrderID:   "sub2_20260522abc",
		Amount:    "12.34",
		Subject:   "AI Gateway 12.34 USDC",
		ReturnURL: "https://example.com/payment/result",
	})
	if err != nil {
		t.Fatalf("CreatePayment returned error: %v", err)
	}
	if resp.TradeNo != "chk_123" || resp.PayURL != "https://payments.coinbase.com/payment-links/pl_123" || resp.QRCode == "" {
		t.Fatalf("unexpected create response: %+v", resp)
	}
	if gotBody.Amount != "12.34" || gotBody.Currency != "USDC" {
		t.Fatalf("checkout amount = %s %s, want 12.34 USDC", gotBody.Amount, gotBody.Currency)
	}
	if gotBody.Metadata["orderId"] != "sub2_20260522abc" || gotBody.Metadata["order_id"] != "sub2_20260522abc" {
		t.Fatalf("metadata = %+v, want both orderId and order_id", gotBody.Metadata)
	}
	if gotBody.SuccessRedirectURL != "https://example.com/payment/result" || gotBody.FailRedirectURL != "https://example.com/payment/result" {
		t.Fatalf("redirect urls = %q / %q", gotBody.SuccessRedirectURL, gotBody.FailRedirectURL)
	}
}

func TestCoinbaseVerifyNotification(t *testing.T) {
	prov, err := NewCoinbase("1", testCoinbaseConfig(t, "", "USDC"))
	if err != nil {
		t.Fatalf("NewCoinbase returned error: %v", err)
	}
	raw := `{"id":"chk_123","url":"https://payments.coinbase.com/payment-links/pl_123","amount":"12.34","currency":"USDC","eventType":"checkout.payment.success","metadata":{"orderId":"sub2_order"},"status":"COMPLETED","transactionHash":"0xabc"}`
	headers := map[string]string{
		"content-type": "application/json",
		"x-hook0-id":   "evt_123",
	}
	headers["x-hook0-signature"] = coinbaseHook0Signature(raw, "whsec", time.Now().Unix(), "content-type x-hook0-id", headers)

	n, err := prov.VerifyNotification(context.Background(), raw, headers)
	if err != nil {
		t.Fatalf("VerifyNotification returned error: %v", err)
	}
	if n == nil {
		t.Fatal("VerifyNotification returned nil notification")
	}
	if n.TradeNo != "chk_123" || n.OrderID != "sub2_order" || n.Status != payment.NotificationStatusSuccess {
		t.Fatalf("unexpected notification: %+v", n)
	}
	if n.Amount != 12.34 || n.Metadata["currency"] != "USDC" || n.Metadata["status"] != "COMPLETED" || n.Metadata["transaction_hash"] != "0xabc" {
		t.Fatalf("unexpected amount/metadata: amount=%v metadata=%v", n.Amount, n.Metadata)
	}
}

func TestCoinbaseQueryOrderMapsStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/checkouts/chk_123" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); !strings.HasPrefix(got, "Bearer ") {
			t.Fatalf("Authorization = %q, want bearer JWT", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chk_123","amount":"12.34","currency":"USDC","status":"COMPLETED"}`))
	}))
	defer server.Close()

	prov, err := NewCoinbase("1", testCoinbaseConfig(t, server.URL, "USDC"))
	if err != nil {
		t.Fatalf("NewCoinbase returned error: %v", err)
	}
	resp, err := prov.QueryOrder(context.Background(), "chk_123")
	if err != nil {
		t.Fatalf("QueryOrder returned error: %v", err)
	}
	if resp.Status != payment.ProviderStatusPaid || resp.TradeNo != "chk_123" || resp.Amount != 12.34 {
		t.Fatalf("unexpected query response: %+v", resp)
	}
}

func TestCoinbaseDefaultsCurrencyToUSDC(t *testing.T) {
	t.Parallel()

	prov, err := NewCoinbase("1", testCoinbaseConfig(t, "", ""))
	if err != nil {
		t.Fatalf("NewCoinbase returned error: %v", err)
	}
	if got := prov.currency(); got != "USDC" {
		t.Fatalf("currency = %q, want USDC", got)
	}
}

func TestCoinbaseWebhookRejectsStaleSignature(t *testing.T) {
	raw := `{"id":"chk_123","eventType":"checkout.payment.success","status":"COMPLETED"}`
	headers := map[string]string{
		"content-type": "application/json",
		"x-hook0-id":   "evt_123",
	}
	headers["x-hook0-signature"] = coinbaseHook0Signature(raw, "whsec", time.Now().Add(-10*time.Minute).Unix(), "content-type x-hook0-id", headers)

	if err := verifyCoinbaseWebhookSignature(raw, headers, "whsec"); err == nil {
		t.Fatal("verifyCoinbaseWebhookSignature returned nil error for stale signature")
	}
}

func TestCoinbaseIdempotencyUUIDIsStableV4(t *testing.T) {
	first := coinbaseIdempotencyUUID("checkout-sub2_order")
	second := coinbaseIdempotencyUUID("checkout-sub2_order")
	if first != second {
		t.Fatalf("coinbaseIdempotencyUUID is not stable: %q != %q", first, second)
	}
	id, err := uuid.Parse(first)
	if err != nil || id.Version() != 4 {
		t.Fatalf("coinbaseIdempotencyUUID = %q, want UUID v4", first)
	}
}

func testCoinbaseConfig(t *testing.T, apiBase, currency string) map[string]string {
	t.Helper()
	return map[string]string{
		"apiKeyId":      "organizations/test-org/apiKeys/test-key",
		"apiKeySecret":  testCoinbaseECPrivateKey(t),
		"webhookSecret": "whsec",
		"apiBase":       apiBase,
		"currency":      currency,
	}
}

func testCoinbaseECPrivateKey(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate EC key: %v", err)
	}
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatalf("marshal EC key: %v", err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}))
}

func coinbaseHook0Signature(raw, secret string, timestamp int64, headerNames string, headers map[string]string) string {
	values := make([]string, 0, len(strings.Fields(headerNames)))
	for _, name := range strings.Fields(headerNames) {
		values = append(values, headers[strings.ToLower(name)])
	}
	signedPayload := fmt.Sprintf("%d.%s.%s.%s", timestamp, headerNames, strings.Join(values, "."), raw)
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(signedPayload))
	return fmt.Sprintf("t=%d,h=%s,v1=%s", timestamp, headerNames, hex.EncodeToString(mac.Sum(nil)))
}
