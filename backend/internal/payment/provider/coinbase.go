package provider

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/coinbase/cdp-sdk/go/auth"
	"github.com/google/uuid"
	"github.com/shopspring/decimal"
)

const (
	coinbaseDefaultAPIBase   = "https://business.coinbase.com/api/v1"
	coinbaseHTTPTimeout      = 15 * time.Second
	coinbaseMaxResponseSize  = 1 << 20
	coinbaseMaxErrorSummary  = 512
	coinbaseJWTExpiresIn     = int64(120)
	coinbaseWebhookMaxAge    = 5 * time.Minute
	coinbaseWebhookFutureAge = time.Minute

	coinbaseEventPaymentSuccess = "checkout.payment.success"
	coinbaseEventPaymentFailed  = "checkout.payment.failed"
	coinbaseEventPaymentExpired = "checkout.payment.expired"

	coinbaseCheckoutStatusActive            = "ACTIVE"
	coinbaseCheckoutStatusProcessing        = "PROCESSING"
	coinbaseCheckoutStatusDeactivated       = "DEACTIVATED"
	coinbaseCheckoutStatusExpired           = "EXPIRED"
	coinbaseCheckoutStatusCompleted         = "COMPLETED"
	coinbaseCheckoutStatusFailed            = "FAILED"
	coinbaseCheckoutStatusRefunded          = "REFUNDED"
	coinbaseCheckoutStatusPartiallyRefunded = "PARTIALLY_REFUNDED"

	coinbaseRefundStatusPending = "PENDING"
	coinbaseRefundStatusSuccess = "COMPLETED"
	coinbaseRefundStatusFailed  = "FAILED"
)

// Coinbase implements Coinbase Business hosted crypto checkouts.
type Coinbase struct {
	instanceID string
	config     map[string]string
	httpClient *http.Client
}

func NewCoinbase(instanceID string, config map[string]string) (*Coinbase, error) {
	for _, k := range []string{"apiKeyId", "apiKeySecret", "webhookSecret"} {
		if strings.TrimSpace(config[k]) == "" {
			return nil, fmt.Errorf("coinbase config missing required key: %s", k)
		}
	}
	cfg := cloneStringMap(config)
	apiBase, err := normalizeCoinbaseAPIBase(cfg["apiBase"])
	if err != nil {
		return nil, err
	}
	cfg["apiBase"] = apiBase
	if strings.TrimSpace(cfg["currency"]) == "" {
		cfg["currency"] = "USDC"
	}
	currency, err := payment.NormalizePaymentCurrency(cfg["currency"])
	if err != nil {
		return nil, fmt.Errorf("coinbase config currency: %w", err)
	}
	cfg["currency"] = currency
	return &Coinbase{
		instanceID: instanceID,
		config:     cfg,
		httpClient: &http.Client{Timeout: coinbaseHTTPTimeout},
	}, nil
}

func normalizeCoinbaseAPIBase(raw string) (string, error) {
	base := strings.TrimSpace(raw)
	if base == "" {
		base = coinbaseDefaultAPIBase
	}
	parsed, err := url.Parse(base)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", fmt.Errorf("coinbase apiBase must be a URL")
	}
	if parsed.Scheme != "https" && !(parsed.Scheme == "http" && isLoopbackHost(parsed.Hostname())) {
		return "", fmt.Errorf("coinbase apiBase must use HTTPS")
	}
	parsed.RawQuery = ""
	parsed.Fragment = ""
	parsed.RawPath = ""
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	return parsed.String(), nil
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (c *Coinbase) Name() string        { return "Coinbase Business" }
func (c *Coinbase) ProviderKey() string { return payment.TypeCoinbase }
func (c *Coinbase) SupportedTypes() []payment.PaymentType {
	return []payment.PaymentType{payment.TypeCrypto}
}

func (c *Coinbase) MerchantIdentityMetadata() map[string]string {
	if c == nil {
		return nil
	}
	return map[string]string{"currency": c.currency()}
}

func (c *Coinbase) currency() string {
	if c == nil {
		return payment.DefaultPaymentCurrency
	}
	currency, err := payment.NormalizePaymentCurrency(c.config["currency"])
	if err != nil {
		return payment.DefaultPaymentCurrency
	}
	return currency
}

func (c *Coinbase) CreatePayment(ctx context.Context, req payment.CreatePaymentRequest) (*payment.CreatePaymentResponse, error) {
	amount, err := decimal.NewFromString(req.Amount)
	if err != nil || amount.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("coinbase create checkout: invalid amount %s", req.Amount)
	}
	currency := c.currency()
	description := strings.TrimSpace(req.Subject)
	if description == "" {
		description = req.OrderID
	}
	payload := coinbaseCreateCheckoutRequest{
		Amount:             amount.StringFixed(int32(payment.CurrencyMaxFractionDigits(currency))),
		Currency:           currency,
		Description:        description,
		SuccessRedirectURL: req.ReturnURL,
		FailRedirectURL:    req.ReturnURL,
		Metadata: map[string]string{
			"orderId":  req.OrderID,
			"order_id": req.OrderID,
		},
	}

	var resp coinbaseCheckout
	if err := c.doJSON(ctx, http.MethodPost, "/checkouts", payload, &resp, "checkout-"+req.OrderID); err != nil {
		return nil, fmt.Errorf("coinbase create checkout: %w", err)
	}
	if strings.TrimSpace(resp.ID) == "" || strings.TrimSpace(resp.URL) == "" {
		return nil, fmt.Errorf("coinbase create checkout: missing checkout id or url")
	}
	return &payment.CreatePaymentResponse{
		TradeNo:  resp.ID,
		PayURL:   resp.URL,
		QRCode:   resp.URL,
		Currency: currency,
	}, nil
}

func (c *Coinbase) QueryOrder(ctx context.Context, tradeNo string) (*payment.QueryOrderResponse, error) {
	tradeNo = strings.TrimSpace(tradeNo)
	if tradeNo == "" {
		return nil, fmt.Errorf("coinbase query checkout: missing checkout id")
	}
	var resp coinbaseCheckout
	if err := c.doJSON(ctx, http.MethodGet, "/checkouts/"+url.PathEscape(tradeNo), nil, &resp, ""); err != nil {
		return nil, fmt.Errorf("coinbase query checkout: %w", err)
	}
	amount, currency := resp.paymentAmount(c.currency())
	metadata := map[string]string{
		"currency": currency,
		"status":   resp.normalizedStatus(),
	}
	if txHash := strings.TrimSpace(resp.TransactionHash); txHash != "" {
		metadata["transaction_hash"] = txHash
	}
	return &payment.QueryOrderResponse{
		TradeNo:  resp.ID,
		Status:   coinbaseProviderStatus(resp.Status),
		Amount:   amount,
		Metadata: metadata,
	}, nil
}

func (c *Coinbase) VerifyNotification(_ context.Context, rawBody string, headers map[string]string) (*payment.PaymentNotification, error) {
	if err := verifyCoinbaseWebhookSignature(rawBody, headers, c.config["webhookSecret"]); err != nil {
		return nil, err
	}

	var event coinbaseCheckoutWebhook
	if err := json.Unmarshal([]byte(rawBody), &event); err != nil {
		return nil, fmt.Errorf("coinbase parse webhook: %w", err)
	}
	switch strings.TrimSpace(event.EventType) {
	case coinbaseEventPaymentSuccess:
		if !strings.EqualFold(event.Status, coinbaseCheckoutStatusCompleted) {
			return nil, fmt.Errorf("coinbase webhook status mismatch: expected COMPLETED, got %s", event.Status)
		}
		return c.notificationFromCheckout(event.coinbaseCheckout, payment.NotificationStatusSuccess, rawBody, event.EventType)
	case coinbaseEventPaymentFailed, coinbaseEventPaymentExpired:
		return nil, nil
	default:
		return nil, nil
	}
}

func (c *Coinbase) notificationFromCheckout(checkout coinbaseCheckout, status, rawBody, eventType string) (*payment.PaymentNotification, error) {
	orderID := coinbaseMetadataOrderID(checkout.Metadata)
	if orderID == "" {
		return nil, fmt.Errorf("coinbase webhook missing metadata.orderId")
	}
	amount, currency := checkout.paymentAmount(c.currency())
	if amount <= 0 {
		return nil, fmt.Errorf("coinbase webhook missing payment amount")
	}
	tradeNo := strings.TrimSpace(checkout.ID)
	if tradeNo == "" {
		return nil, fmt.Errorf("coinbase webhook missing checkout id")
	}
	metadata := map[string]string{
		"currency":   currency,
		"status":     checkout.normalizedStatus(),
		"event_type": strings.TrimSpace(eventType),
	}
	if txHash := strings.TrimSpace(checkout.TransactionHash); txHash != "" {
		metadata["transaction_hash"] = txHash
	}
	return &payment.PaymentNotification{
		TradeNo:  tradeNo,
		OrderID:  orderID,
		Amount:   amount,
		Status:   status,
		RawData:  rawBody,
		Metadata: metadata,
	}, nil
}

func (c *Coinbase) Refund(ctx context.Context, req payment.RefundRequest) (*payment.RefundResponse, error) {
	tradeNo := strings.TrimSpace(req.TradeNo)
	if tradeNo == "" {
		return nil, fmt.Errorf("coinbase refund: missing checkout id")
	}
	amount, err := decimal.NewFromString(req.Amount)
	if err != nil || amount.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("coinbase refund: invalid amount %s", req.Amount)
	}
	currency := c.currency()
	payload := coinbaseRefundCheckoutRequest{
		Amount:   amount.StringFixed(int32(payment.CurrencyMaxFractionDigits(currency))),
		Currency: currency,
		Reason:   strings.TrimSpace(req.Reason),
	}
	var resp coinbaseCheckout
	idempotencyKey := strings.TrimSpace("refund-" + req.OrderID + "-" + req.Amount)
	if err := c.doJSON(ctx, http.MethodPost, "/checkouts/"+url.PathEscape(tradeNo)+"/refund", payload, &resp, idempotencyKey); err != nil {
		return nil, fmt.Errorf("coinbase refund checkout: %w", err)
	}
	refund := resp.latestRefund()
	refundID := strings.TrimSpace(refund.ID)
	if refundID == "" {
		refundID = resp.ID
	}
	return &payment.RefundResponse{
		RefundID: refundID,
		Status:   coinbaseRefundProviderStatus(refund.Status),
	}, nil
}

// CancelPayment deactivates an active Coinbase checkout when a local order is cancelled.
func (c *Coinbase) CancelPayment(ctx context.Context, tradeNo string) error {
	tradeNo = strings.TrimSpace(tradeNo)
	if tradeNo == "" {
		return fmt.Errorf("coinbase deactivate checkout: missing checkout id")
	}
	return c.doJSON(ctx, http.MethodPost, "/checkouts/"+url.PathEscape(tradeNo)+"/deactivate", nil, nil, "")
}

func (c *Coinbase) doJSON(ctx context.Context, method, path string, payload any, out any, idempotencyKey string) error {
	var bodyReader io.Reader
	if payload != nil {
		body, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		bodyReader = bytes.NewReader(body)
	}
	reqURL, err := c.endpoint(path)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, method, reqURL, bodyReader)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if idempotencyKey = strings.TrimSpace(idempotencyKey); idempotencyKey != "" {
		req.Header.Set("X-Idempotency-Key", coinbaseIdempotencyUUID(idempotencyKey))
	}
	if err := c.authorize(req); err != nil {
		return err
	}

	body, status, err := c.do(req)
	if err != nil {
		return err
	}
	if status < http.StatusOK || status >= http.StatusMultipleChoices {
		return fmt.Errorf("HTTP %d: %s", status, summarizeCoinbaseResponse(body))
	}
	if out == nil || len(bytes.TrimSpace(body)) == 0 {
		return nil
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("parse response: %w", err)
	}
	return nil
}

func (c *Coinbase) endpoint(path string) (string, error) {
	base := strings.TrimRight(c.config["apiBase"], "/")
	if base == "" {
		return "", fmt.Errorf("coinbase apiBase not configured")
	}
	return base + "/" + strings.TrimLeft(path, "/"), nil
}

func (c *Coinbase) authorize(req *http.Request) error {
	token, err := auth.GenerateJWT(auth.JwtOptions{
		KeyID:         strings.TrimSpace(c.config["apiKeyId"]),
		KeySecret:     strings.TrimSpace(c.config["apiKeySecret"]),
		RequestMethod: strings.ToUpper(req.Method),
		RequestHost:   req.URL.Host,
		RequestPath:   coinbaseJWTRequestPath(req.URL),
		ExpiresIn:     coinbaseJWTExpiresIn,
	})
	if err != nil {
		return fmt.Errorf("coinbase generate JWT: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	return nil
}

func coinbaseJWTRequestPath(u *url.URL) string {
	path := u.EscapedPath()
	if path == "" {
		path = "/"
	}
	if u.RawQuery != "" {
		path += "?" + u.RawQuery
	}
	return path
}

func coinbaseIdempotencyUUID(seed string) string {
	if strings.TrimSpace(seed) == "" {
		return uuid.NewString()
	}
	sum := sha256.Sum256([]byte(seed))
	var id uuid.UUID
	copy(id[:], sum[:16])
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	return id.String()
}

func (c *Coinbase) do(req *http.Request) ([]byte, int, error) {
	client := c.httpClient
	if client == nil {
		client = &http.Client{Timeout: coinbaseHTTPTimeout}
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, coinbaseMaxResponseSize))
	if err != nil {
		return nil, resp.StatusCode, err
	}
	return body, resp.StatusCode, nil
}

func summarizeCoinbaseResponse(body []byte) string {
	summary := strings.TrimSpace(string(body))
	if len(summary) > coinbaseMaxErrorSummary {
		summary = summary[:coinbaseMaxErrorSummary] + "...(truncated)"
	}
	return summary
}

func verifyCoinbaseWebhookSignature(rawBody string, headers map[string]string, secret string) error {
	secret = strings.TrimSpace(secret)
	if secret == "" {
		return fmt.Errorf("coinbase webhookSecret not configured")
	}
	normalizedHeaders := normalizeHeaderMap(headers)
	signatureHeader := strings.TrimSpace(normalizedHeaders["x-hook0-signature"])
	if signatureHeader == "" {
		return fmt.Errorf("coinbase notification missing x-hook0-signature header")
	}
	values := parseCoinbaseHook0Signature(signatureHeader)
	timestampRaw := values["t"]
	headerNames := values["h"]
	signatureHex := values["v1"]
	if timestampRaw == "" || headerNames == "" || signatureHex == "" {
		return fmt.Errorf("coinbase invalid x-hook0-signature header")
	}
	timestamp, err := parseCoinbaseSignatureTimestamp(timestampRaw)
	if err != nil {
		return err
	}
	if age := time.Since(timestamp); age > coinbaseWebhookMaxAge {
		return fmt.Errorf("coinbase webhook signature expired")
	}
	if futureAge := time.Until(timestamp); futureAge > coinbaseWebhookFutureAge {
		return fmt.Errorf("coinbase webhook signature timestamp is too far in the future")
	}
	headerValues, err := coinbaseSignedHeaderValues(headerNames, normalizedHeaders)
	if err != nil {
		return err
	}
	signedPayload := strings.Join([]string{timestampRaw, headerNames, headerValues, rawBody}, ".")
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(signedPayload))
	expected := mac.Sum(nil)
	actual, err := hex.DecodeString(strings.TrimSpace(signatureHex))
	if err != nil {
		return fmt.Errorf("coinbase invalid signature encoding")
	}
	if !hmac.Equal(expected, actual) {
		return fmt.Errorf("coinbase invalid signature")
	}
	return nil
}

func normalizeHeaderMap(headers map[string]string) map[string]string {
	normalized := make(map[string]string, len(headers))
	for k, v := range headers {
		normalized[strings.ToLower(strings.TrimSpace(k))] = strings.TrimSpace(v)
	}
	return normalized
}

func parseCoinbaseHook0Signature(raw string) map[string]string {
	parts := strings.Split(raw, ",")
	out := make(map[string]string, len(parts))
	for _, part := range parts {
		key, value, ok := strings.Cut(strings.TrimSpace(part), "=")
		if ok {
			out[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return out
}

func parseCoinbaseSignatureTimestamp(raw string) (time.Time, error) {
	seconds, err := decimal.NewFromString(strings.TrimSpace(raw))
	if err != nil {
		return time.Time{}, fmt.Errorf("coinbase invalid signature timestamp")
	}
	return time.Unix(seconds.IntPart(), 0), nil
}

func coinbaseSignedHeaderValues(headerNames string, headers map[string]string) (string, error) {
	names := strings.Fields(headerNames)
	values := make([]string, 0, len(names))
	for _, name := range names {
		value, ok := headers[strings.ToLower(strings.TrimSpace(name))]
		if !ok {
			return "", fmt.Errorf("coinbase signed header %s missing", name)
		}
		values = append(values, value)
	}
	return strings.Join(values, "."), nil
}

func coinbaseProviderStatus(status string) string {
	switch strings.ToUpper(strings.TrimSpace(status)) {
	case coinbaseCheckoutStatusCompleted:
		return payment.ProviderStatusPaid
	case coinbaseCheckoutStatusRefunded:
		return payment.ProviderStatusRefunded
	case coinbaseCheckoutStatusDeactivated, coinbaseCheckoutStatusExpired, coinbaseCheckoutStatusFailed:
		return payment.ProviderStatusFailed
	case coinbaseCheckoutStatusPartiallyRefunded:
		return payment.ProviderStatusPaid
	case coinbaseCheckoutStatusActive, coinbaseCheckoutStatusProcessing:
		return payment.ProviderStatusPending
	default:
		return payment.ProviderStatusPending
	}
}

func coinbaseRefundProviderStatus(status string) string {
	switch strings.ToUpper(strings.TrimSpace(status)) {
	case coinbaseRefundStatusSuccess:
		return payment.ProviderStatusSuccess
	case coinbaseRefundStatusFailed:
		return payment.ProviderStatusFailed
	case coinbaseRefundStatusPending, "":
		return payment.ProviderStatusPending
	default:
		return payment.ProviderStatusPending
	}
}

func coinbaseMetadataOrderID(metadata map[string]string) string {
	if metadata == nil {
		return ""
	}
	if orderID := strings.TrimSpace(metadata["orderId"]); orderID != "" {
		return orderID
	}
	return strings.TrimSpace(metadata["order_id"])
}

type coinbaseCreateCheckoutRequest struct {
	Amount             string            `json:"amount"`
	Currency           string            `json:"currency"`
	Description        string            `json:"description,omitempty"`
	Metadata           map[string]string `json:"metadata,omitempty"`
	SuccessRedirectURL string            `json:"successRedirectUrl,omitempty"`
	FailRedirectURL    string            `json:"failRedirectUrl,omitempty"`
	ExpiresAt          string            `json:"expiresAt,omitempty"`
}

type coinbaseRefundCheckoutRequest struct {
	Amount   string `json:"amount"`
	Currency string `json:"currency,omitempty"`
	Reason   string `json:"reason,omitempty"`
}

type coinbaseCheckoutWebhook struct {
	coinbaseCheckout
	EventType string `json:"eventType"`
}

type coinbaseCheckout struct {
	ID                 string             `json:"id"`
	URL                string             `json:"url"`
	Amount             coinbaseAmount     `json:"amount"`
	Currency           string             `json:"currency"`
	Status             string             `json:"status"`
	FiatAmount         coinbaseAmount     `json:"fiatAmount"`
	FiatCurrency       string             `json:"fiatCurrency"`
	Metadata           map[string]string  `json:"metadata"`
	TransactionHash    string             `json:"transactionHash"`
	Settlement         coinbaseSettlement `json:"settlement"`
	Refunds            []coinbaseRefund   `json:"refunds"`
	SuccessRedirectURL string             `json:"successRedirectUrl"`
	FailRedirectURL    string             `json:"failRedirectUrl"`
}

type coinbaseSettlement struct {
	TotalAmount coinbaseAmount `json:"totalAmount"`
	FeeAmount   coinbaseAmount `json:"feeAmount"`
	NetAmount   coinbaseAmount `json:"netAmount"`
	Currency    string         `json:"currency"`
}

type coinbaseRefund struct {
	ID              string         `json:"id"`
	CheckoutID      string         `json:"checkoutId"`
	Amount          coinbaseAmount `json:"amount"`
	Currency        string         `json:"currency"`
	Status          string         `json:"status"`
	Reason          string         `json:"reason"`
	TransactionHash string         `json:"transactionHash"`
}

type coinbaseAmount string

func (a *coinbaseAmount) UnmarshalJSON(data []byte) error {
	raw := strings.TrimSpace(string(data))
	if raw == "" || raw == "null" {
		*a = ""
		return nil
	}
	if strings.HasPrefix(raw, "\"") {
		var s string
		if err := json.Unmarshal(data, &s); err != nil {
			return err
		}
		*a = coinbaseAmount(s)
		return nil
	}
	*a = coinbaseAmount(raw)
	return nil
}

func (a coinbaseAmount) String() string {
	return string(a)
}

func (c coinbaseCheckout) normalizedStatus() string {
	return strings.ToUpper(strings.TrimSpace(c.Status))
}

func (c coinbaseCheckout) paymentAmount(fallbackCurrency string) (float64, string) {
	fallback, err := payment.NormalizePaymentCurrency(fallbackCurrency)
	if err != nil {
		fallback = payment.DefaultPaymentCurrency
	}
	if amount, currency, ok := parseCoinbaseAmount(c.FiatAmount.String(), c.FiatCurrency, fallback); ok && strings.EqualFold(currency, fallback) {
		return amount, currency
	}
	if amount, currency, ok := parseCoinbaseAmount(c.Amount.String(), c.Currency, fallback); ok && strings.EqualFold(currency, fallback) {
		return amount, currency
	}
	if amount, currency, ok := parseCoinbaseAmount(c.Amount.String(), c.Currency, fallback); ok {
		return amount, currency
	}
	if amount, currency, ok := parseCoinbaseAmount(c.FiatAmount.String(), c.FiatCurrency, fallback); ok {
		return amount, currency
	}
	return 0, fallback
}

func parseCoinbaseAmount(rawAmount, rawCurrency, fallbackCurrency string) (float64, string, bool) {
	rawAmount = strings.TrimSpace(rawAmount)
	if rawAmount == "" {
		return 0, fallbackCurrency, false
	}
	amount, err := decimal.NewFromString(rawAmount)
	if err != nil {
		return 0, fallbackCurrency, false
	}
	currency, err := payment.NormalizePaymentCurrency(rawCurrency)
	if err != nil {
		currency = fallbackCurrency
	}
	return amount.InexactFloat64(), currency, true
}

func (c coinbaseCheckout) latestRefund() coinbaseRefund {
	if len(c.Refunds) == 0 {
		return coinbaseRefund{}
	}
	return c.Refunds[len(c.Refunds)-1]
}

var (
	_ payment.Provider                 = (*Coinbase)(nil)
	_ payment.CancelableProvider       = (*Coinbase)(nil)
	_ payment.MerchantIdentityProvider = (*Coinbase)(nil)
)
