import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import RegisterView from '@/views/auth/RegisterView.vue'

const {
  pushMock,
  registerMock,
  showSuccessMock,
  getPublicSettingsMock,
  routeState,
} = vi.hoisted(() => ({
  pushMock: vi.fn(),
  registerMock: vi.fn(),
  showSuccessMock: vi.fn(),
  getPublicSettingsMock: vi.fn(),
  routeState: {
    query: {} as Record<string, unknown>,
  },
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: () => ({ push: pushMock }),
    useRoute: () => routeState,
  }
})

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string, params?: Record<string, string | number>) => {
        return key
      },
      locale: { value: 'zh-CN' },
    }),
  }
})

vi.mock('@/stores', () => ({
  useAuthStore: () => ({
    register: (...args: any[]) => registerMock(...args),
  }),
  useAppStore: () => ({
    showSuccess: (...args: any[]) => showSuccessMock(...args),
    showError: vi.fn(),
    showWarning: vi.fn(),
    siteName: 'AI Gateway',
    siteLogo: '',
    cachedPublicSettings: { site_subtitle: 'AI API Gateway Platform' },
    fetchPublicSettings: vi.fn().mockResolvedValue(null),
  }),
}))

vi.mock('@/api/auth', async () => {
  const actual = await vi.importActual<typeof import('@/api/auth')>('@/api/auth')
  return {
    ...actual,
    getPublicSettings: (...args: any[]) => getPublicSettingsMock(...args),
    validatePromoCode: vi.fn(),
    validateInvitationCode: vi.fn(),
  }
})

const mountRegister = () =>
  mount(RegisterView, {
    global: {
      stubs: {
        AuthLayout: { template: '<div><slot /><slot name="footer" /></div>' },
        EmailOAuthButtons: true,
        LinuxDoOAuthSection: true,
        WechatOAuthSection: true,
        OidcOAuthSection: true,
        LoginAgreementPrompt: true,
        TurnstileWidget: true,
        Icon: true,
        RouterLink: true,
        transition: false,
      },
    },
  })

describe('RegisterView affiliate referrals', () => {
  beforeEach(() => {
    pushMock.mockReset()
    registerMock.mockReset()
    showSuccessMock.mockReset()
    getPublicSettingsMock.mockReset()
    routeState.query = {}
    localStorage.clear()
    sessionStorage.clear()
    registerMock.mockResolvedValue({})
    getPublicSettingsMock.mockResolvedValue({
      registration_enabled: true,
      email_verify_enabled: false,
      promo_code_enabled: false,
      invitation_code_enabled: false,
      affiliate_enabled: true,
      turnstile_enabled: false,
      turnstile_site_key: '',
      site_name: 'AI Gateway',
      registration_email_suffix_whitelist: [],
      linuxdo_oauth_enabled: false,
      wechat_oauth_enabled: false,
      wechat_oauth_open_enabled: false,
      wechat_oauth_mp_enabled: false,
      oidc_oauth_enabled: false,
      oidc_oauth_provider_name: 'OIDC',
      github_oauth_enabled: false,
      google_oauth_enabled: false,
    })
  })

  it('prefills the affiliate code field from the link and sends it with registration', async () => {
    routeState.query = { aff: ' AFF123 ' }
    const wrapper = mountRegister()
    await flushPromises()

    expect((wrapper.get('#aff_code').element as HTMLInputElement).value).toBe('AFF123')
    expect(wrapper.text()).not.toContain('auth.affiliateReferralApplied')

    await wrapper.get('#email').setValue('new@example.com')
    await wrapper.get('#password').setValue('secret-123')
    await wrapper.get('form').trigger('submit')
    await flushPromises()

    expect(registerMock).toHaveBeenCalledWith({
      email: 'new@example.com',
      password: 'secret-123',
      turnstile_token: undefined,
      promo_code: undefined,
      invitation_code: undefined,
      aff_code: 'AFF123',
    })
  })

  it('allows registration without an affiliate code', async () => {
    const wrapper = mountRegister()
    await flushPromises()

    await wrapper.get('#email').setValue('plain@example.com')
    await wrapper.get('#password').setValue('secret-plain')
    await wrapper.get('form').trigger('submit')
    await flushPromises()

    expect(registerMock).toHaveBeenCalledWith({
      email: 'plain@example.com',
      password: 'secret-plain',
      turnstile_token: undefined,
      promo_code: undefined,
      invitation_code: undefined,
    })
  })

  it('does not submit a stored affiliate code after the user clears the field', async () => {
    routeState.query = { aff: 'AFF123' }
    const wrapper = mountRegister()
    await flushPromises()

    await wrapper.get('#aff_code').setValue('')
    await wrapper.get('#email').setValue('clear@example.com')
    await wrapper.get('#password').setValue('secret-clear')
    await wrapper.get('form').trigger('submit')
    await flushPromises()

    expect(registerMock).toHaveBeenCalledWith({
      email: 'clear@example.com',
      password: 'secret-clear',
      turnstile_token: undefined,
      promo_code: undefined,
      invitation_code: undefined,
    })
  })

  it('preserves the invite code when email verification is required', async () => {
    getPublicSettingsMock.mockResolvedValue({
      registration_enabled: true,
      email_verify_enabled: true,
      promo_code_enabled: false,
      invitation_code_enabled: false,
      affiliate_enabled: true,
      turnstile_enabled: false,
      turnstile_site_key: '',
      site_name: 'AI Gateway',
      registration_email_suffix_whitelist: [],
    })
    routeState.query = { aff_code: 'REF456' }
    const wrapper = mountRegister()
    await flushPromises()

    await wrapper.get('#email').setValue('verify@example.com')
    await wrapper.get('#password').setValue('secret-456')
    await wrapper.get('form').trigger('submit')
    await flushPromises()

    expect(registerMock).not.toHaveBeenCalled()
    expect(pushMock).toHaveBeenCalledWith('/email-verify')
    expect(JSON.parse(sessionStorage.getItem('register_data') || '{}')).toMatchObject({
      email: 'verify@example.com',
      password: 'secret-456',
      aff_code: 'REF456',
    })
  })
})
