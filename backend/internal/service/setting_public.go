package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/url"
	"strconv"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/pkg/timezone"
)

func normalizeLoginAgreementMode(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "checkbox":
		return "checkbox"
	default:
		return defaultLoginAgreementMode
	}
}

const (
	defaultTermsContentMD = `## 服务说明

AI Gateway 提供统一 API 网关、账号调度、用量统计和余额扣费能力。用户提交请求后，系统会根据可用账号、分组规则、模型映射和风控配置将请求转发到对应的上游模型服务。

## 用户责任

- 请确认你的使用场景符合所在地法律法规、上游模型服务条款以及本平台的使用政策。
- 不要提交违法内容、恶意攻击内容、他人敏感信息，或你无权处理的数据。
- 请自行保护你的 API Key、登录密码、二次验证设备和团队成员权限。

## 服务边界

- 上游模型的可用性、响应质量、限流策略和内容安全策略由对应第三方服务决定。
- 系统可能因为余额不足、配额限制、风控规则、上游限流、账号异常或维护而拒绝或延迟请求。
- 管理员可以根据运营、安全或合规要求调整可用模型、账号分组、倍率、限额和访问规则。`

	defaultUsagePolicyContentMD = `## 禁止用途

不得使用本平台从事下列行为：

- 生成、传播或协助实施违法、欺诈、侵权、恶意攻击、垃圾信息或规避安全控制的内容。
- 未经授权处理他人的个人信息、商业秘密、认证凭证、源代码或其他敏感资料。
- 批量撞库、扫描、滥发请求、绕过限流、共享或转售未经授权的 API Key。
- 试图攻击、干扰、逆向、绕过或滥用本平台、上游服务或其他用户资源。

## 风控措施

为保护平台和其他用户，系统可能执行频率限制、IP 访问控制、内容审核、账号切换、请求拒绝、密钥禁用、账号暂停或人工复核。

## 违规处理

如果检测到异常或违规使用，管理员可以限制、暂停或终止相关账号/API Key，并保留必要的安全审计记录用于排障、风控和合规处理。`

	defaultSupportedRegionsContentMD = `## 可用地区

服务是否可用取决于部署节点、网络连通性、支付方式、上游服务条款以及当地法律法规。管理员可以按需限制注册、登录、支付、模型访问或特定地区的使用。

## 用户确认

- 你需要自行确认访问和使用本平台以及上游 AI 服务在你所在地是被允许的。
- 如果上游服务、支付服务或网络服务不支持你所在地区，相关功能可能无法使用。
- 如果管理员收到合规、风控或上游服务要求，可能会调整可用地区或限制访问。`

	defaultSecurityPrivacyContentMD = `## 我们处理哪些数据

为提供网关、计费、调度和安全能力，系统会处理并保存必要数据，包括账号邮箱、用户资料、API Key、余额和用量记录、账号分组、上游账号凭证、支付/兑换记录、登录和操作审计记录。

## 请求内容如何处理

- 你的 API 请求会被转发给被调度到的上游模型服务。上游服务会按其自身条款、隐私政策和安全策略处理这些请求。
- 正常用量日志保存请求 ID、用户/API Key/账号/分组、模型、Token、费用、耗时、状态、IP 和 User-Agent 等元数据，不保存 prompt 或 response 正文。
- 运维错误日志用于排障和风控，保存错误阶段、状态码、模型、上游错误信息和必要上下文；系统不保存可重放的完整请求体。
- 如启用内容审核、风控或上游安全策略，相关模块可能会临时读取请求内容用于判定是否放行。

## 凭证与访问控制

- 用户 API Key 用于鉴权和扣费，请像密码一样保管。泄露后应立即删除或轮换。
- 上游账号凭证和 OAuth token 仅用于代表平台调度请求、刷新 token、查询额度和执行必要的隐私/安全设置。
- 管理员后台会对敏感凭证做脱敏展示；具备服务器、数据库或管理员权限的人员仍可能接触系统运行所需的敏感数据。

## 第三方与数据出境

请求可能被转发到 OpenAI、Anthropic、Google、Antigravity 或管理员配置的其他上游/支付/邮件服务。你提交的数据可能因此离开本平台所在服务器，并受对应第三方条款约束。

## 用户建议

- 不要提交你无权处理的个人信息、密钥、密码、私有代码、商业秘密或高度敏感资料。
- 为 API Key 设置额度、过期时间、IP 白名单和合理的速率限制。
- 团队场景中请按最小权限分配账号和密钥，并定期审查用量和访问记录。

## 联系管理员

如需删除账号、处理数据请求、报告安全问题或了解具体部署的保留周期，请联系本平台管理员。`
)

func defaultLoginAgreementDocuments() []LoginAgreementDocument {
	return []LoginAgreementDocument{
		{
			ID:        "terms",
			Title:     "服务条款",
			ContentMD: defaultTermsContentMD,
		},
		{
			ID:        "usage-policy",
			Title:     "使用政策",
			ContentMD: defaultUsagePolicyContentMD,
		},
		{
			ID:        "supported-regions",
			Title:     "支持的国家和地区",
			ContentMD: defaultSupportedRegionsContentMD,
		},
		{
			ID:        "security-privacy",
			Title:     "安全与隐私声明",
			ContentMD: defaultSecurityPrivacyContentMD,
		},
	}
}

func legacyBlankLoginAgreementDocuments() []LoginAgreementDocument {
	return []LoginAgreementDocument{
		{ID: "terms", Title: "服务条款"},
		{ID: "usage-policy", Title: "使用政策"},
		{ID: "supported-regions", Title: "支持的国家和地区"},
		{ID: "service-specific-terms", Title: "服务特定条款"},
	}
}

func isLegacyBlankLoginAgreementDocuments(docs []LoginAgreementDocument) bool {
	legacy := legacyBlankLoginAgreementDocuments()
	if len(docs) != len(legacy) {
		return false
	}
	for i, doc := range docs {
		if strings.TrimSpace(doc.ContentMD) != "" {
			return false
		}
		if strings.TrimSpace(doc.ID) != legacy[i].ID || strings.TrimSpace(doc.Title) != legacy[i].Title {
			return false
		}
	}
	return true
}

func normalizeLoginAgreementDocumentID(raw string) string {
	raw = strings.ToLower(strings.TrimSpace(raw))
	var b strings.Builder
	lastSeparator := false
	for _, r := range raw {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			_, _ = b.WriteRune(r)
			lastSeparator = false
			continue
		}
		if r == '-' || r == '_' || r == ' ' || r == '.' || r == '/' {
			if !lastSeparator && b.Len() > 0 {
				if r == '_' {
					_, _ = b.WriteRune('_')
				} else {
					_, _ = b.WriteRune('-')
				}
				lastSeparator = true
			}
		}
	}
	return strings.Trim(b.String(), "-_")
}

func normalizeLoginAgreementDocuments(docs []LoginAgreementDocument) []LoginAgreementDocument {
	normalized := make([]LoginAgreementDocument, 0, len(docs))
	seen := make(map[string]int, len(docs))
	for i, doc := range docs {
		title := strings.TrimSpace(doc.Title)
		content := strings.TrimSpace(doc.ContentMD)
		if title == "" && content == "" {
			continue
		}
		id := normalizeLoginAgreementDocumentID(doc.ID)
		if id == "" {
			sum := sha256.Sum256([]byte(fmt.Sprintf("%d:%s:%s", i, title, content)))
			id = hex.EncodeToString(sum[:])[:12]
		}
		baseID := id
		for suffix := 2; seen[id] > 0; suffix++ {
			id = fmt.Sprintf("%s-%d", baseID, suffix)
		}
		seen[id]++
		normalized = append(normalized, LoginAgreementDocument{
			ID:        id,
			Title:     title,
			ContentMD: content,
		})
	}
	return normalized
}

func parseLoginAgreementDocuments(raw string) []LoginAgreementDocument {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return defaultLoginAgreementDocuments()
	}
	var docs []LoginAgreementDocument
	if err := json.Unmarshal([]byte(raw), &docs); err != nil {
		return defaultLoginAgreementDocuments()
	}
	docs = normalizeLoginAgreementDocuments(docs)
	if len(docs) == 0 {
		return defaultLoginAgreementDocuments()
	}
	if isLegacyBlankLoginAgreementDocuments(docs) {
		return defaultLoginAgreementDocuments()
	}
	return docs
}

func marshalLoginAgreementDocuments(docs []LoginAgreementDocument) (string, error) {
	normalized := normalizeLoginAgreementDocuments(docs)
	if len(normalized) == 0 {
		normalized = defaultLoginAgreementDocuments()
	}
	b, err := json.Marshal(normalized)
	if err != nil {
		return "", fmt.Errorf("marshal login agreement documents: %w", err)
	}
	return string(b), nil
}

func buildLoginAgreementRevision(updatedAt string, docs []LoginAgreementDocument) string {
	normalized := normalizeLoginAgreementDocuments(docs)
	payload, err := json.Marshal(struct {
		UpdatedAt string                   `json:"updated_at"`
		Documents []LoginAgreementDocument `json:"documents"`
	}{
		UpdatedAt: strings.TrimSpace(updatedAt),
		Documents: normalized,
	})
	if err != nil {
		payload = []byte(strings.TrimSpace(updatedAt))
	}
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:])[:16]
}

// GetFrontendURL 获取前端基础URL（数据库优先，fallback 到配置文件）
func (s *SettingService) GetFrontendURL(ctx context.Context) string {
	val, err := s.settingRepo.GetValue(ctx, SettingKeyFrontendURL)
	if err == nil && strings.TrimSpace(val) != "" {
		return strings.TrimSpace(val)
	}
	return s.cfg.Server.FrontendURL
}

// GetPublicSettings 获取公开设置（无需登录）
func (s *SettingService) GetPublicSettings(ctx context.Context) (*PublicSettings, error) {
	keys := []string{
		SettingKeyRegistrationEnabled,
		SettingKeyEmailVerifyEnabled,
		SettingKeyForceEmailOnThirdPartySignup,
		SettingKeyRegistrationEmailSuffixWhitelist,
		SettingKeyRegistrationEmailDomainQuotaEnabled,
		SettingKeyPromoCodeEnabled,
		SettingKeyPasswordResetEnabled,
		SettingKeyInvitationCodeEnabled,
		SettingKeyTotpEnabled,
		SettingKeyPasskeyEnabled,
		SettingKeyLoginAgreementEnabled,
		SettingKeyLoginAgreementMode,
		SettingKeyLoginAgreementUpdatedAt,
		SettingKeyLoginAgreementDocuments,
		SettingKeyTurnstileEnabled,
		SettingKeyTurnstileSiteKey,
		SettingKeyTencentCaptchaEnabled,
		SettingKeyTencentCaptchaAppID,
		SettingKeyTencentCaptchaRegion,
		SettingKeyAliyunCaptchaEnabled,
		SettingKeyAliyunCaptchaSceneID,
		SettingKeyAliyunCaptchaPrefix,
		SettingKeyAliyunCaptchaRegion,
		SettingKeyAPIKeyACLTrustForwardedIP,
		SettingKeySiteName,
		SettingKeySiteLogo,
		SettingKeySiteSubtitle,
		SettingKeyAPIBaseURL,
		SettingKeyContactInfo,
		SettingKeyDocURL,
		SettingKeyHomeContent,
		SettingKeyCompactHomeEnabled,
		SettingKeyHideCcsImportButton,
		SettingKeyPurchaseSubscriptionEnabled,
		SettingKeyPurchaseSubscriptionURL,
		SettingKeyTableDefaultPageSize,
		SettingKeyTablePageSizeOptions,
		SettingKeyCustomMenuItems,
		SettingKeyCustomEndpoints,
		SettingKeyLinuxDoConnectEnabled,
		SettingKeyDingTalkConnectEnabled,
		SettingKeyWeChatConnectEnabled,
		SettingKeyWeChatConnectAppID,
		SettingKeyWeChatConnectAppSecret,
		SettingKeyWeChatConnectOpenAppID,
		SettingKeyWeChatConnectOpenAppSecret,
		SettingKeyWeChatConnectMPAppID,
		SettingKeyWeChatConnectMPAppSecret,
		SettingKeyWeChatConnectMobileAppID,
		SettingKeyWeChatConnectMobileAppSecret,
		SettingKeyWeChatConnectOpenEnabled,
		SettingKeyWeChatConnectMPEnabled,
		SettingKeyWeChatConnectMobileEnabled,
		SettingKeyWeChatConnectMode,
		SettingKeyWeChatConnectScopes,
		SettingKeyWeChatConnectRedirectURL,
		SettingKeyWeChatConnectFrontendRedirectURL,
		SettingKeyBackendModeEnabled,
		SettingPaymentEnabled,
		SettingKeyOIDCConnectEnabled,
		SettingKeyOIDCConnectProviderName,
		SettingKeyGitHubOAuthEnabled,
		SettingKeyGitHubOAuthClientID,
		SettingKeyGitHubOAuthClientSecret,
		SettingKeyGoogleOAuthEnabled,
		SettingKeyGoogleOAuthClientID,
		SettingKeyGoogleOAuthClientSecret,
		SettingKeyBalanceLowNotifyEnabled,
		SettingKeyBalanceLowNotifyThreshold,
		SettingKeyBalanceLowNotifyRechargeURL,
		SettingKeyAccountQuotaNotifyEnabled,
		SettingKeyChannelMonitorEnabled,
		SettingKeyChannelMonitorMode,
		SettingKeyChannelMonitorDefaultIntervalSeconds,
		SettingKeyChannelMonitorHideThroughput,
		SettingKeyChannelMonitorShowQuota,
		SettingKeyAvailableChannelsEnabled,
		SettingKeyModelPlazaEnabled,
		SettingKeyModelPlazaRequireAuth,
		SettingKeyPluginManagementEnabled,
		SettingKeyAffiliateEnabled,
		SettingKeyRiskControlEnabled,
		SettingKeyAllowUserViewErrorRequests,
	}

	settings, err := s.settingRepo.GetMultiple(ctx, keys)
	if err != nil {
		return nil, fmt.Errorf("get public settings: %w", err)
	}

	linuxDoEnabled := false
	if raw, ok := settings[SettingKeyLinuxDoConnectEnabled]; ok {
		linuxDoEnabled = raw == "true"
	} else {
		linuxDoEnabled = s.cfg != nil && s.cfg.LinuxDo.Enabled
	}
	dingTalkEnabled := false
	if raw, ok := settings[SettingKeyDingTalkConnectEnabled]; ok {
		dingTalkEnabled = raw == "true"
	} else {
		dingTalkEnabled = s.cfg != nil && s.cfg.DingTalk.Enabled
	}
	oidcEnabled := false
	if raw, ok := settings[SettingKeyOIDCConnectEnabled]; ok {
		oidcEnabled = raw == "true"
	} else {
		oidcEnabled = s.cfg != nil && s.cfg.OIDC.Enabled
	}
	oidcProviderName := strings.TrimSpace(settings[SettingKeyOIDCConnectProviderName])
	if oidcProviderName == "" && s.cfg != nil {
		oidcProviderName = strings.TrimSpace(s.cfg.OIDC.ProviderName)
	}
	if oidcProviderName == "" {
		oidcProviderName = "OIDC"
	}
	gitHubEnabled := s.emailOAuthPublicEnabled(settings, "github")
	googleEnabled := s.emailOAuthPublicEnabled(settings, "google")
	weChatEnabled, weChatOpenEnabled, weChatMPEnabled, weChatMobileEnabled := s.weChatOAuthCapabilitiesFromSettings(settings)

	// Password reset requires email verification to be enabled
	emailVerifyEnabled := settings[SettingKeyEmailVerifyEnabled] == "true"
	passwordResetEnabled := emailVerifyEnabled && settings[SettingKeyPasswordResetEnabled] == "true"
	registrationEmailSuffixWhitelist := ParseRegistrationEmailSuffixWhitelist(
		settings[SettingKeyRegistrationEmailSuffixWhitelist],
	)
	tableDefaultPageSize, tablePageSizeOptions := parseTablePreferences(
		settings[SettingKeyTableDefaultPageSize],
		settings[SettingKeyTablePageSizeOptions],
	)
	loginAgreementDocuments := parseLoginAgreementDocuments(settings[SettingKeyLoginAgreementDocuments])
	loginAgreementUpdatedAt := strings.TrimSpace(settings[SettingKeyLoginAgreementUpdatedAt])
	if loginAgreementUpdatedAt == "" {
		loginAgreementUpdatedAt = defaultLoginAgreementDate
	}

	var balanceLowNotifyThreshold float64
	if v, err := strconv.ParseFloat(settings[SettingKeyBalanceLowNotifyThreshold], 64); err == nil && v >= 0 {
		balanceLowNotifyThreshold = v
	}

	return &PublicSettings{
		RegistrationEnabled:              settings[SettingKeyRegistrationEnabled] == "true",
		EmailVerifyEnabled:               emailVerifyEnabled,
		ForceEmailOnThirdPartySignup:     settings[SettingKeyForceEmailOnThirdPartySignup] == "true",
		RegistrationEmailSuffixWhitelist: registrationEmailSuffixWhitelist,
		PromoCodeEnabled:                 settings[SettingKeyPromoCodeEnabled] != "false", // 默认启用
		PasswordResetEnabled:             passwordResetEnabled,
		InvitationCodeEnabled:            settings[SettingKeyInvitationCodeEnabled] == "true",
		TotpEnabled:                      settings[SettingKeyTotpEnabled] == "true",
		PasskeyEnabled:                   s.passkeyConfigured() && s.passkeySettingEnabled(settings),
		LoginAgreementEnabled:            settings[SettingKeyLoginAgreementEnabled] == "true" && len(loginAgreementDocuments) > 0,
		LoginAgreementMode:               normalizeLoginAgreementMode(settings[SettingKeyLoginAgreementMode]),
		LoginAgreementUpdatedAt:          loginAgreementUpdatedAt,
		LoginAgreementRevision:           buildLoginAgreementRevision(loginAgreementUpdatedAt, loginAgreementDocuments),
		LoginAgreementDocuments:          loginAgreementDocuments,
		TurnstileEnabled:                 settings[SettingKeyTurnstileEnabled] == "true",
		TurnstileSiteKey:                 settings[SettingKeyTurnstileSiteKey],
		SiteName:                         s.getStringOrDefault(settings, SettingKeySiteName, defaultSiteName),
		SiteLogo:                         settings[SettingKeySiteLogo],
		SiteSubtitle:                     s.getStringOrDefault(settings, SettingKeySiteSubtitle, defaultSiteSubtitle),
		APIBaseURL:                       settings[SettingKeyAPIBaseURL],
		ContactInfo:                      settings[SettingKeyContactInfo],
		DocURL:                           settings[SettingKeyDocURL],
		HomeContent:                      settings[SettingKeyHomeContent],
		CompactHomeEnabled:               settings[SettingKeyCompactHomeEnabled] == "true",
		HideCcsImportButton:              settings[SettingKeyHideCcsImportButton] == "true",
		PurchaseSubscriptionEnabled:      settings[SettingKeyPurchaseSubscriptionEnabled] == "true",
		PurchaseSubscriptionURL:          strings.TrimSpace(settings[SettingKeyPurchaseSubscriptionURL]),
		TableDefaultPageSize:             tableDefaultPageSize,
		TablePageSizeOptions:             tablePageSizeOptions,
		CustomMenuItems:                  settings[SettingKeyCustomMenuItems],
		CustomEndpoints:                  settings[SettingKeyCustomEndpoints],
		LinuxDoOAuthEnabled:              linuxDoEnabled,
		DingTalkOAuthEnabled:             dingTalkEnabled,
		WeChatOAuthEnabled:               weChatEnabled,
		WeChatOAuthOpenEnabled:           weChatOpenEnabled,
		WeChatOAuthMPEnabled:             weChatMPEnabled,
		WeChatOAuthMobileEnabled:         weChatMobileEnabled,
		BackendModeEnabled:               settings[SettingKeyBackendModeEnabled] == "true",
		PaymentEnabled:                   settings[SettingPaymentEnabled] == "true",
		OIDCOAuthEnabled:                 oidcEnabled,
		OIDCOAuthProviderName:            oidcProviderName,
		GitHubOAuthEnabled:               gitHubEnabled,
		GoogleOAuthEnabled:               googleEnabled,
		BalanceLowNotifyEnabled:          settings[SettingKeyBalanceLowNotifyEnabled] == "true",
		AccountQuotaNotifyEnabled:        settings[SettingKeyAccountQuotaNotifyEnabled] == "true",
		BalanceLowNotifyThreshold:        balanceLowNotifyThreshold,
		BalanceLowNotifyRechargeURL:      settings[SettingKeyBalanceLowNotifyRechargeURL],

		ChannelMonitorEnabled:                !isFalseSettingValue(settings[SettingKeyChannelMonitorEnabled]),
		ChannelMonitorMode:                   normalizeChannelMonitorMode(settings[SettingKeyChannelMonitorMode]),
		ChannelMonitorDefaultIntervalSeconds: parseChannelMonitorInterval(settings[SettingKeyChannelMonitorDefaultIntervalSeconds]),
		ChannelMonitorHideThroughput:         !isFalseSettingValue(settings[SettingKeyChannelMonitorHideThroughput]),
		ChannelMonitorShowQuota:              settings[SettingKeyChannelMonitorShowQuota] == "true",

		AvailableChannelsEnabled: settings[SettingKeyAvailableChannelsEnabled] == "true",

		ModelPlazaEnabled:       settings[SettingKeyModelPlazaEnabled] == "true",
		ModelPlazaRequireAuth:   settings[SettingKeyModelPlazaRequireAuth] == "true",
		PluginManagementEnabled: settings[SettingKeyPluginManagementEnabled] == "true",

		AffiliateEnabled: !isFalseSettingValue(settings[SettingKeyAffiliateEnabled]),

		RiskControlEnabled: settings[SettingKeyRiskControlEnabled] == "true",

		AllowUserViewErrorRequests: settings[SettingKeyAllowUserViewErrorRequests] == "true",
	}, nil
}

// channelMonitorIntervalMin / channelMonitorIntervalMax bound the default interval
// (mirrors the monitor-level constraint but lives here so setting_service stays decoupled).
const (
	channelMonitorIntervalMin      = 15
	channelMonitorIntervalMax      = 3600
	channelMonitorIntervalFallback = 60
	defaultChannelMonitorMode      = ChannelMonitorModeV1
)

// normalizeChannelMonitorMode accepts only v1/v2; empty/invalid → v1 (safe default).
func normalizeChannelMonitorMode(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case ChannelMonitorModeV1, "":
		return ChannelMonitorModeV1
	case ChannelMonitorModeV2:
		return ChannelMonitorModeV2
	default:
		return defaultChannelMonitorMode
	}
}

// parseChannelMonitorInterval parses the stored string and clamps to [15, 3600].
// Empty / invalid input falls back to channelMonitorIntervalFallback.
func parseChannelMonitorInterval(raw string) int {
	v, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return channelMonitorIntervalFallback
	}
	return clampChannelMonitorInterval(v)
}

// clampChannelMonitorInterval clamps v to the allowed range. 0 means "not provided".
func clampChannelMonitorInterval(v int) int {
	if v <= 0 {
		return 0
	}
	if v < channelMonitorIntervalMin {
		return channelMonitorIntervalMin
	}
	if v > channelMonitorIntervalMax {
		return channelMonitorIntervalMax
	}
	return v
}

// ChannelMonitorRuntime is the lightweight view of the channel monitor feature
// consumed by the runner, V2 aggregator, and user-facing handlers.
type ChannelMonitorRuntime struct {
	Enabled                bool
	Mode                   string // ChannelMonitorModeV1 or ChannelMonitorModeV2
	DefaultIntervalSeconds int
	// HideThroughput: when true, user-facing V2 APIs omit RPM/TPM scale signals.
	HideThroughput bool
	// ShowQuota: when true, user-facing monitor views keep the quota/balance
	// snapshots; otherwise the user handler strips them server-side.
	// Parsed fail-closed (only literal "true" enables). Admin always sees them.
	ShowQuota bool
}

// ActiveProbesAllowed reports whether V1 active provider probes may run.
func (r ChannelMonitorRuntime) ActiveProbesAllowed() bool {
	return r.Enabled && r.Mode == ChannelMonitorModeV1
}

// PassiveAggregationAllowed reports whether V2 passive aggregation may run.
func (r ChannelMonitorRuntime) PassiveAggregationAllowed() bool {
	return r.Enabled && r.Mode == ChannelMonitorModeV2
}

// GetChannelMonitorRuntime reads the channel monitor feature flags directly from
// the settings store. Fail-open: on error returns Enabled=true, Mode=v1, default interval.
func (s *SettingService) GetChannelMonitorRuntime(ctx context.Context) ChannelMonitorRuntime {
	if s == nil || s.settingRepo == nil {
		return ChannelMonitorRuntime{
			Enabled:                true,
			Mode:                   defaultChannelMonitorMode,
			DefaultIntervalSeconds: channelMonitorIntervalFallback,
			HideThroughput:         true,
		}
	}
	vals, err := s.settingRepo.GetMultiple(ctx, []string{
		SettingKeyChannelMonitorEnabled,
		SettingKeyChannelMonitorMode,
		SettingKeyChannelMonitorDefaultIntervalSeconds,
		SettingKeyChannelMonitorHideThroughput,
		SettingKeyChannelMonitorShowQuota,
	})
	if err != nil {
		return ChannelMonitorRuntime{
			Enabled:                true,
			Mode:                   defaultChannelMonitorMode,
			DefaultIntervalSeconds: channelMonitorIntervalFallback,
			HideThroughput:         true,
		}
	}
	return ChannelMonitorRuntime{
		Enabled:                !isFalseSettingValue(vals[SettingKeyChannelMonitorEnabled]),
		Mode:                   normalizeChannelMonitorMode(vals[SettingKeyChannelMonitorMode]),
		DefaultIntervalSeconds: parseChannelMonitorInterval(vals[SettingKeyChannelMonitorDefaultIntervalSeconds]),
		HideThroughput:         !isFalseSettingValue(vals[SettingKeyChannelMonitorHideThroughput]),
		ShowQuota:              vals[SettingKeyChannelMonitorShowQuota] == "true",
	}
}

// AvailableChannelsRuntime is the lightweight view of the available-channels feature
// switch consumed by the user-facing handler.
type AvailableChannelsRuntime struct {
	Enabled bool
}

// GetAvailableChannelsRuntime reads the available-channels feature switch directly
// from the settings store. Fail-closed: on error returns Enabled=false, matching
// the opt-in default (unknown ↔ disabled).
func (s *SettingService) GetAvailableChannelsRuntime(ctx context.Context) AvailableChannelsRuntime {
	vals, err := s.settingRepo.GetMultiple(ctx, []string{SettingKeyAvailableChannelsEnabled})
	if err != nil {
		return AvailableChannelsRuntime{Enabled: false}
	}
	return AvailableChannelsRuntime{
		Enabled: vals[SettingKeyAvailableChannelsEnabled] == "true",
	}
}

// ModelPlazaRuntime is the lightweight view of the model-plaza feature consumed
// by the public plaza handler.
type ModelPlazaRuntime struct {
	Enabled     bool
	RequireAuth bool
	Description string
}

// GetModelPlazaRuntime reads the model-plaza feature switches directly from the
// settings store. Fail-closed: on error returns Enabled=false, matching the
// opt-in default (unknown ↔ disabled).
func (s *SettingService) GetModelPlazaRuntime(ctx context.Context) ModelPlazaRuntime {
	vals, err := s.settingRepo.GetMultiple(ctx, []string{
		SettingKeyModelPlazaEnabled,
		SettingKeyModelPlazaRequireAuth,
		SettingKeyModelPlazaDescription,
	})
	if err != nil {
		return ModelPlazaRuntime{Enabled: false}
	}
	return ModelPlazaRuntime{
		Enabled:     vals[SettingKeyModelPlazaEnabled] == "true",
		RequireAuth: vals[SettingKeyModelPlazaRequireAuth] == "true",
		Description: vals[SettingKeyModelPlazaDescription],
	}
}

// IsUserErrorViewAllowed reads the user-facing error-requests visibility switch
// directly from the settings store. Fail-closed: on error returns false (opt-in default).
func (s *SettingService) IsUserErrorViewAllowed(ctx context.Context) bool {
	vals, err := s.settingRepo.GetMultiple(ctx, []string{SettingKeyAllowUserViewErrorRequests})
	if err != nil {
		slog.Warn("failed to get allow_user_view_error_requests setting, defaulting to false", "error", err)
		return false
	}
	return vals[SettingKeyAllowUserViewErrorRequests] == "true"
}

// PublicSettingsInjectionPayload is the JSON shape embedded into HTML as
// `window.__APP_CONFIG__` so the frontend can hydrate feature flags & site
// config before the first XHR finishes.
//
// INVARIANT: every `json` tag here MUST also exist on handler/dto.PublicSettings.
// If you forget a feature-flag field here, the frontend's
// `cachedPublicSettings.xxx_enabled` will be `undefined` on refresh until the
// async `/api/v1/settings/public` call returns — which causes opt-in menus
// (strict `=== true`) to flicker off/on. See
// frontend/src/utils/featureFlags.ts for the matching registry.
//
// A unit test diffs this struct's JSON keys against dto.PublicSettings to catch
// drift automatically (see setting_service_injection_test.go).
type PublicSettingsInjectionPayload struct {
	RegistrationEnabled                 bool                     `json:"registration_enabled"`
	EmailVerifyEnabled                  bool                     `json:"email_verify_enabled"`
	RegistrationEmailSuffixWhitelist    []string                 `json:"registration_email_suffix_whitelist"`
	RegistrationEmailDomainQuotaEnabled bool                     `json:"registration_email_domain_quota_enabled"`
	PromoCodeEnabled                    bool                     `json:"promo_code_enabled"`
	PasswordResetEnabled                bool                     `json:"password_reset_enabled"`
	InvitationCodeEnabled               bool                     `json:"invitation_code_enabled"`
	TotpEnabled                         bool                     `json:"totp_enabled"`
	PasskeyEnabled                      bool                     `json:"passkey_enabled"`
	LoginAgreementEnabled               bool                     `json:"login_agreement_enabled"`
	LoginAgreementMode                  string                   `json:"login_agreement_mode"`
	LoginAgreementUpdatedAt             string                   `json:"login_agreement_updated_at"`
	LoginAgreementRevision              string                   `json:"login_agreement_revision"`
	LoginAgreementDocuments             []LoginAgreementDocument `json:"login_agreement_documents"`
	TurnstileEnabled                    bool                     `json:"turnstile_enabled"`
	TurnstileSiteKey                    string                   `json:"turnstile_site_key"`
	TencentCaptchaEnabled               bool                     `json:"tencent_captcha_enabled"`
	TencentCaptchaAppID                 string                   `json:"tencent_captcha_app_id"`
	TencentCaptchaRegion                string                   `json:"tencent_captcha_region"`
	AliyunCaptchaEnabled                bool                     `json:"aliyun_captcha_enabled"`
	AliyunCaptchaSceneID                string                   `json:"aliyun_captcha_scene_id"`
	AliyunCaptchaPrefix                 string                   `json:"aliyun_captcha_prefix"`
	AliyunCaptchaRegion                 string                   `json:"aliyun_captcha_region"`
	SiteName                            string                   `json:"site_name"`
	SiteLogo                            string                   `json:"site_logo"`
	SiteSubtitle                        string                   `json:"site_subtitle"`
	APIBaseURL                          string                   `json:"api_base_url"`
	ContactInfo                         string                   `json:"contact_info"`
	DocURL                              string                   `json:"doc_url"`
	HomeContent                         string                   `json:"home_content"`
	CompactHomeEnabled                  bool                     `json:"compact_home_enabled"`
	HideCcsImportButton                 bool                     `json:"hide_ccs_import_button"`
	PurchaseSubscriptionEnabled         bool                     `json:"purchase_subscription_enabled"`
	PurchaseSubscriptionURL             string                   `json:"purchase_subscription_url"`
	TableDefaultPageSize                int                      `json:"table_default_page_size"`
	TablePageSizeOptions                []int                    `json:"table_page_size_options"`
	CustomMenuItems                     json.RawMessage          `json:"custom_menu_items"`
	CustomEndpoints                     json.RawMessage          `json:"custom_endpoints"`
	LinuxDoOAuthEnabled                 bool                     `json:"linuxdo_oauth_enabled"`
	DingTalkOAuthEnabled                bool                     `json:"dingtalk_oauth_enabled"`
	WeChatOAuthEnabled                  bool                     `json:"wechat_oauth_enabled"`
	WeChatOAuthOpenEnabled              bool                     `json:"wechat_oauth_open_enabled"`
	WeChatOAuthMPEnabled                bool                     `json:"wechat_oauth_mp_enabled"`
	WeChatOAuthMobileEnabled            bool                     `json:"wechat_oauth_mobile_enabled"`
	OIDCOAuthEnabled                    bool                     `json:"oidc_oauth_enabled"`
	OIDCOAuthProviderName               string                   `json:"oidc_oauth_provider_name"`
	GitHubOAuthEnabled                  bool                     `json:"github_oauth_enabled"`
	GoogleOAuthEnabled                  bool                     `json:"google_oauth_enabled"`
	BackendModeEnabled                  bool                     `json:"backend_mode_enabled"`
	PaymentEnabled                      bool                     `json:"payment_enabled"`
	Version                             string                   `json:"version"`
	// 服务器全局时区（IANA 名称与当前 UTC 偏移），高峰时段等服务端本地时间窗口的展示标注用
	ServerTimezone              string  `json:"server_timezone"`
	ServerUTCOffset             string  `json:"server_utc_offset"`
	BalanceLowNotifyEnabled     bool    `json:"balance_low_notify_enabled"`
	AccountQuotaNotifyEnabled   bool    `json:"account_quota_notify_enabled"`
	BalanceLowNotifyThreshold   float64 `json:"balance_low_notify_threshold"`
	BalanceLowNotifyRechargeURL string  `json:"balance_low_notify_recharge_url"`

	// Feature flags — MUST match the opt-in/opt-out registry in
	// frontend/src/utils/featureFlags.ts. Missing a field here is the bug
	// that hid the "可用渠道" menu on page refresh.
	ChannelMonitorEnabled                bool   `json:"channel_monitor_enabled"`
	ChannelMonitorMode                   string `json:"channel_monitor_mode"`
	ChannelMonitorDefaultIntervalSeconds int    `json:"channel_monitor_default_interval_seconds"`
	// ChannelMonitorHideThroughput is public so the user UI can hide RPM/TPM
	// without waiting for API redaction alone (defense in depth).
	ChannelMonitorHideThroughput bool `json:"channel_monitor_hide_throughput"`
	// ChannelMonitorShowQuota gates the user-facing quota/balance display on
	// monitors; fail-closed (absent/false = hidden). Admin UI always shows it.
	ChannelMonitorShowQuota    bool `json:"channel_monitor_show_quota"`
	AvailableChannelsEnabled   bool `json:"available_channels_enabled"`
	ModelPlazaEnabled          bool `json:"model_plaza_enabled"`
	ModelPlazaRequireAuth      bool `json:"model_plaza_require_auth"`
	PluginManagementEnabled    bool `json:"plugin_management_enabled"`
	AffiliateEnabled           bool `json:"affiliate_enabled"`
	RiskControlEnabled         bool `json:"risk_control_enabled"`
	AllowUserViewErrorRequests bool `json:"allow_user_view_error_requests"`
}

// GetPublicSettingsForInjection returns public settings in a format suitable for HTML injection.
// This implements the web.PublicSettingsProvider interface.
func (s *SettingService) GetPublicSettingsForInjection(ctx context.Context) (any, error) {
	settings, err := s.GetPublicSettings(ctx)
	if err != nil {
		return nil, err
	}

	return &PublicSettingsInjectionPayload{
		RegistrationEnabled:                 settings.RegistrationEnabled,
		EmailVerifyEnabled:                  settings.EmailVerifyEnabled,
		RegistrationEmailSuffixWhitelist:    settings.RegistrationEmailSuffixWhitelist,
		RegistrationEmailDomainQuotaEnabled: settings.RegistrationEmailDomainQuotaEnabled,
		PromoCodeEnabled:                    settings.PromoCodeEnabled,
		PasswordResetEnabled:                settings.PasswordResetEnabled,
		InvitationCodeEnabled:               settings.InvitationCodeEnabled,
		TotpEnabled:                         settings.TotpEnabled,
		PasskeyEnabled:                      settings.PasskeyEnabled,
		LoginAgreementEnabled:               settings.LoginAgreementEnabled,
		LoginAgreementMode:                  settings.LoginAgreementMode,
		LoginAgreementUpdatedAt:             settings.LoginAgreementUpdatedAt,
		LoginAgreementRevision:              settings.LoginAgreementRevision,
		LoginAgreementDocuments:             settings.LoginAgreementDocuments,
		TurnstileEnabled:                    settings.TurnstileEnabled,
		TurnstileSiteKey:                    settings.TurnstileSiteKey,
		TencentCaptchaEnabled:               settings.TencentCaptchaEnabled,
		TencentCaptchaAppID:                 settings.TencentCaptchaAppID,
		TencentCaptchaRegion:                settings.TencentCaptchaRegion,
		AliyunCaptchaEnabled:                settings.AliyunCaptchaEnabled,
		AliyunCaptchaSceneID:                settings.AliyunCaptchaSceneID,
		AliyunCaptchaPrefix:                 settings.AliyunCaptchaPrefix,
		AliyunCaptchaRegion:                 settings.AliyunCaptchaRegion,
		SiteName:                            settings.SiteName,
		SiteLogo:                            settings.SiteLogo,
		SiteSubtitle:                        settings.SiteSubtitle,
		APIBaseURL:                          settings.APIBaseURL,
		ContactInfo:                         settings.ContactInfo,
		DocURL:                              settings.DocURL,
		HomeContent:                         settings.HomeContent,
		CompactHomeEnabled:                  settings.CompactHomeEnabled,
		HideCcsImportButton:                 settings.HideCcsImportButton,
		PurchaseSubscriptionEnabled:         settings.PurchaseSubscriptionEnabled,
		PurchaseSubscriptionURL:             settings.PurchaseSubscriptionURL,
		TableDefaultPageSize:                settings.TableDefaultPageSize,
		TablePageSizeOptions:                settings.TablePageSizeOptions,
		CustomMenuItems:                     filterUserVisibleMenuItems(settings.CustomMenuItems),
		CustomEndpoints:                     safeRawJSONArray(settings.CustomEndpoints),
		LinuxDoOAuthEnabled:                 settings.LinuxDoOAuthEnabled,
		DingTalkOAuthEnabled:                settings.DingTalkOAuthEnabled,
		WeChatOAuthEnabled:                  settings.WeChatOAuthEnabled,
		WeChatOAuthOpenEnabled:              settings.WeChatOAuthOpenEnabled,
		WeChatOAuthMPEnabled:                settings.WeChatOAuthMPEnabled,
		WeChatOAuthMobileEnabled:            settings.WeChatOAuthMobileEnabled,
		OIDCOAuthEnabled:                    settings.OIDCOAuthEnabled,
		OIDCOAuthProviderName:               settings.OIDCOAuthProviderName,
		GitHubOAuthEnabled:                  settings.GitHubOAuthEnabled,
		GoogleOAuthEnabled:                  settings.GoogleOAuthEnabled,
		BackendModeEnabled:                  settings.BackendModeEnabled,
		PaymentEnabled:                      settings.PaymentEnabled,
		Version:                             s.version,
		ServerTimezone:                      timezone.Name(),
		ServerUTCOffset:                     timezone.UTCOffset(),
		BalanceLowNotifyEnabled:             settings.BalanceLowNotifyEnabled,
		AccountQuotaNotifyEnabled:           settings.AccountQuotaNotifyEnabled,
		BalanceLowNotifyThreshold:           settings.BalanceLowNotifyThreshold,
		BalanceLowNotifyRechargeURL:         settings.BalanceLowNotifyRechargeURL,

		ChannelMonitorEnabled:                settings.ChannelMonitorEnabled,
		ChannelMonitorMode:                   settings.ChannelMonitorMode,
		ChannelMonitorDefaultIntervalSeconds: settings.ChannelMonitorDefaultIntervalSeconds,
		ChannelMonitorHideThroughput:         settings.ChannelMonitorHideThroughput,
		ChannelMonitorShowQuota:              settings.ChannelMonitorShowQuota,
		AvailableChannelsEnabled:             settings.AvailableChannelsEnabled,
		ModelPlazaEnabled:                    settings.ModelPlazaEnabled,
		ModelPlazaRequireAuth:                settings.ModelPlazaRequireAuth,
		PluginManagementEnabled:              settings.PluginManagementEnabled,
		AffiliateEnabled:                     settings.AffiliateEnabled,
		RiskControlEnabled:                   settings.RiskControlEnabled,
		AllowUserViewErrorRequests:           settings.AllowUserViewErrorRequests,
	}, nil
}

// filterUserVisibleMenuItems filters out admin-only menu items from a raw JSON
// array string, returning only items with visibility != "admin".
func filterUserVisibleMenuItems(raw string) json.RawMessage {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "[]" {
		return json.RawMessage("[]")
	}
	var items []struct {
		Visibility string `json:"visibility"`
	}
	if err := json.Unmarshal([]byte(raw), &items); err != nil {
		return json.RawMessage("[]")
	}

	// Parse full items to preserve all fields
	var fullItems []json.RawMessage
	if err := json.Unmarshal([]byte(raw), &fullItems); err != nil {
		return json.RawMessage("[]")
	}

	var filtered []json.RawMessage
	for i, item := range items {
		if item.Visibility != "admin" {
			filtered = append(filtered, fullItems[i])
		}
	}
	if len(filtered) == 0 {
		return json.RawMessage("[]")
	}
	result, err := json.Marshal(filtered)
	if err != nil {
		return json.RawMessage("[]")
	}
	return result
}

// safeRawJSONArray returns raw as json.RawMessage if it's valid JSON, otherwise "[]".
func safeRawJSONArray(raw string) json.RawMessage {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return json.RawMessage("[]")
	}
	if json.Valid([]byte(raw)) {
		return json.RawMessage(raw)
	}
	return json.RawMessage("[]")
}

// GetFrameSrcOrigins returns deduplicated http(s) origins from home_content URL,
// purchase_subscription_url, and all custom_menu_items URLs. Used by the router layer for CSP frame-src injection.
func (s *SettingService) GetFrameSrcOrigins(ctx context.Context) ([]string, error) {
	settings, err := s.GetPublicSettings(ctx)
	if err != nil {
		return nil, err
	}

	seen := make(map[string]struct{})
	var origins []string

	addOrigin := func(rawURL string) {
		if origin := extractOriginFromURL(rawURL); origin != "" {
			if _, ok := seen[origin]; !ok {
				seen[origin] = struct{}{}
				origins = append(origins, origin)
			}
		}
	}

	// home content URL (when home_content is set to a URL for iframe embedding)
	addOrigin(settings.HomeContent)

	// purchase subscription URL
	if settings.PurchaseSubscriptionEnabled {
		addOrigin(settings.PurchaseSubscriptionURL)
	}

	// all custom menu items (including admin-only, since CSP must allow all iframes)
	for _, item := range parseCustomMenuItemURLs(settings.CustomMenuItems) {
		addOrigin(item)
	}

	return origins, nil
}

// extractOriginFromURL returns the scheme+host origin from rawURL.
// Only http and https schemes are accepted.
func extractOriginFromURL(rawURL string) string {
	rawURL = strings.TrimSpace(rawURL)
	if rawURL == "" {
		return ""
	}
	u, err := url.Parse(rawURL)
	if err != nil || u.Host == "" {
		return ""
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return ""
	}
	return u.Scheme + "://" + u.Host
}

// parseCustomMenuItemURLs extracts URLs from a raw JSON array of custom menu items.
func parseCustomMenuItemURLs(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "[]" {
		return nil
	}
	var items []struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal([]byte(raw), &items); err != nil {
		return nil
	}
	urls := make([]string, 0, len(items))
	for _, item := range items {
		if item.URL != "" {
			urls = append(urls, item.URL)
		}
	}
	return urls
}
