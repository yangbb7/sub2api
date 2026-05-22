package service

import (
	"math"
	"strconv"
	"strings"

	dbent "github.com/Wei-Shaw/sub2api/ent"
	"github.com/Wei-Shaw/sub2api/internal/payment"
	infraerrors "github.com/Wei-Shaw/sub2api/internal/pkg/errors"
)

const providerConfigCreditRateToUSD = "creditRateToUsd"

func paymentProviderConfigCurrency(providerKey string, cfg map[string]string) string {
	switch strings.TrimSpace(providerKey) {
	case payment.TypeStripe, payment.TypeAirwallex, payment.TypeCoinbase:
		if strings.TrimSpace(providerKey) == payment.TypeCoinbase && strings.TrimSpace(cfg["currency"]) == "" {
			return "USDC"
		}
		currency, err := payment.NormalizePaymentCurrency(cfg["currency"])
		if err == nil {
			return currency
		}
	}
	return payment.DefaultPaymentCurrency
}

func paymentProviderCreditRateToUSD(sel *payment.InstanceSelection, globalRate float64) float64 {
	if sel == nil {
		return normalizeBalanceRechargeMultiplier(globalRate)
	}
	return paymentProviderConfigCreditRateToUSD(sel.ProviderKey, sel.Config, globalRate)
}

func paymentProviderConfigCreditRateToUSD(providerKey string, cfg map[string]string, globalRate float64) float64 {
	if rate, ok := parseProviderCreditRateToUSD(cfg); ok {
		return rate
	}
	currency := paymentProviderConfigCurrency(providerKey, cfg)
	switch strings.ToUpper(strings.TrimSpace(currency)) {
	case "USD", "USDC":
		return 1
	}
	return normalizeBalanceRechargeMultiplier(globalRate)
}

func parseProviderCreditRateToUSD(cfg map[string]string) (float64, bool) {
	if cfg == nil {
		return 0, false
	}
	raw := strings.TrimSpace(cfg[providerConfigCreditRateToUSD])
	if raw == "" {
		return 0, false
	}
	rate, err := strconv.ParseFloat(raw, 64)
	if err != nil || math.IsNaN(rate) || math.IsInf(rate, 0) || rate <= 0 {
		return 0, false
	}
	return rate, true
}

func validateProviderCreditRateToUSDConfig(cfg map[string]string) error {
	if cfg == nil || strings.TrimSpace(cfg[providerConfigCreditRateToUSD]) == "" {
		return nil
	}
	if _, ok := parseProviderCreditRateToUSD(cfg); !ok {
		return infraerrors.BadRequest("VALIDATION_ERROR", "creditRateToUsd must be a positive number")
	}
	return nil
}

func PaymentOrderCurrency(order *dbent.PaymentOrder) string {
	if snapshot := psOrderProviderSnapshot(order); snapshot != nil {
		if currency, err := payment.NormalizePaymentCurrency(snapshot.Currency); err == nil {
			return currency
		}
	}
	return payment.DefaultPaymentCurrency
}
