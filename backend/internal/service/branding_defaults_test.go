package service

import (
	"testing"

	dbent "github.com/Wei-Shaw/sub2api/ent"
	"github.com/Wei-Shaw/sub2api/internal/payment"
)

func TestRuntimeBrandingDefaultsDoNotExposeLegacyName(t *testing.T) {
	if defaultSiteName != "AI Gateway" {
		t.Fatalf("defaultSiteName = %q, want AI Gateway", defaultSiteName)
	}
	if totpIssuer != defaultSiteName {
		t.Fatalf("totpIssuer = %q, want %q", totpIssuer, defaultSiteName)
	}
	if debugGatewayBodyEnv != "GATEWAY_DEBUG_GATEWAY_BODY" {
		t.Fatalf("debugGatewayBodyEnv = %q, want GATEWAY_DEBUG_GATEWAY_BODY", debugGatewayBodyEnv)
	}
}

func TestPaymentSubjectDefaultsUseNeutralBrand(t *testing.T) {
	svc := &PaymentService{}
	cfg := &PaymentConfig{}

	if got := svc.buildPaymentSubject(&dbent.SubscriptionPlan{Name: "Pro"}, 10, cfg, nil); got != "AI Gateway Subscription Pro" {
		t.Fatalf("subscription subject = %q", got)
	}

	if got := svc.buildPaymentSubject(nil, 12.5, cfg, &payment.InstanceSelection{}); got != "AI Gateway 12.50 CNY" {
		t.Fatalf("balance subject = %q", got)
	}
}
