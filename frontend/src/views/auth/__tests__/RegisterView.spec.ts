import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import RegisterView from '@/views/auth/RegisterView.vue'

enableAutoUnmount(afterEach)

const { sendVerifyCodeMock, getPublicSettingsMock, registerMock, showErrorMock, pushMock, verifyActionMock, appStoreMock } = vi.hoisted(() => ({
  sendVerifyCodeMock: vi.fn(),
  getPublicSettingsMock: vi.fn(),
  registerMock: vi.fn(),
  showErrorMock: vi.fn(),
  pushMock: vi.fn(),
  verifyActionMock: vi.fn(),
  appStoreMock: {
    cachedPublicSettings: null as { promo_code_enabled?: boolean } | null,
    showError: (...args: unknown[]) => showErrorMock(...args),
    showSuccess: vi.fn(),
    showWarning: vi.fn()
  }
}))

const publicSettings = {
  registration_enabled: true,
  email_verify_enabled: false,
  promo_code_enabled: false,
  invitation_code_enabled: false,
  affiliate_enabled: true,
  turnstile_enabled: true,
  turnstile_site_key: 'site-key',
  site_name: 'Sub2API',
  registration_email_suffix_whitelist: [],
  linuxdo_oauth_enabled: false,
  wechat_oauth_enabled: false,
  oidc_oauth_enabled: false,
  github_oauth_enabled: false,
  google_oauth_enabled: false
}

vi.mock('vue-router', () => ({
  useRouter: () => ({ push: pushMock }),
  useRoute: () => ({ query: {} })
}))

vi.mock('vue-i18n', () => ({
  createI18n: () => ({
    global: {
      t: (key: string) => key
    }
  }),
  useI18n: () => ({
    t: (key: string) =>
      key === 'auth.emailDomainRegistrationLimit'
        ? '该邮箱域名无法注册新账户。请使用主流邮箱注册；如需使用企业邮箱，请联系客服添加域名白名单。'
        : key,
    locale: { value: 'en' }
  })
}))

vi.mock('@/stores', () => ({
  useAuthStore: () => ({ register: (...args: unknown[]) => registerMock(...args) }),
  useAppStore: () => appStoreMock
}))

vi.mock('@/api/auth', async () => {
  const actual = await vi.importActual<typeof import('@/api/auth')>('@/api/auth')
  return {
    ...actual,
    getPublicSettings: (...args: unknown[]) => getPublicSettingsMock(...args),
    sendVerifyCode: (...args: unknown[]) => sendVerifyCodeMock(...args)
  }
})
function mountRegister() {
  return mount(RegisterView, {
    global: {
      stubs: {
        AuthLayout: { template: '<div><slot /><slot name="footer" /></div>' },
        Icon: true,
        TurnstileWidget: {
          name: 'TurnstileWidget',
          template: '<div data-testid="turnstile-widget" />',
          methods: { verifyAction: verifyActionMock, reset: vi.fn() }
        },
        LoginAgreementPrompt: true,
        EmailOAuthButtons: true,
        LinuxDoOAuthSection: true,
        WechatOAuthSection: true,
        OidcOAuthSection: true,
        RouterLink: true,
        transition: false
      }
    }
  })
}

describe('RegisterView', () => {
  beforeEach(() => {
    sendVerifyCodeMock.mockReset()
    sendVerifyCodeMock.mockResolvedValue({ countdown: 60 })
    getPublicSettingsMock.mockReset()
    registerMock.mockReset()
    showErrorMock.mockReset()
    pushMock.mockReset()
    verifyActionMock.mockReset()
    appStoreMock.cachedPublicSettings = null
    sessionStorage.removeItem('register_data')
    verifyActionMock.mockResolvedValue({ token: 'ticket', randstr: 'randstr' })
    getPublicSettingsMock.mockResolvedValue(publicSettings)
    registerMock.mockResolvedValue({})
  })

  it('does not flash the promo-code field before disabled settings finish loading', async () => {
    let resolveSettings!: (settings: typeof publicSettings) => void
    getPublicSettingsMock.mockReturnValueOnce(
      new Promise<typeof publicSettings>((resolve) => {
        resolveSettings = resolve
      })
    )

    const wrapper = mountRegister()

    expect(wrapper.find('#promo_code').exists()).toBe(false)

    resolveSettings(publicSettings)
    await flushPromises()

    expect(wrapper.find('#promo_code').exists()).toBe(false)
  })

  it('uses injected public settings to show an enabled promo-code field on first render', () => {
    appStoreMock.cachedPublicSettings = { promo_code_enabled: true }
    getPublicSettingsMock.mockReturnValueOnce(new Promise(() => {}))

    const wrapper = mountRegister()

    expect(wrapper.find('#promo_code').exists()).toBe(true)
  })

  it.each([
    ['', 'auth.confirmPasswordRequired'],
    ['different-password', 'auth.passwordsDoNotMatch']
  ])('blocks invalid confirmation %j before captcha and allows correction', async (confirmation, error) => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings,
      turnstile_enabled: false,
      tencent_captcha_enabled: true,
      tencent_captcha_app_id: 'app-id'
    })
    const wrapper = mountRegister()
    await flushPromises()
    await wrapper.get('#email').setValue('user@example.com')
    await wrapper.get('#password').setValue('secret-123')
    await wrapper.get('#confirmPassword').setValue(confirmation)
    await wrapper.get('form').trigger('submit.prevent')
    await flushPromises()

    expect(showErrorMock).toHaveBeenCalledWith(error)
    expect(wrapper.get('#confirmPassword').classes()).toContain('input-error')
    expect(registerMock).not.toHaveBeenCalled()
    expect(verifyActionMock).not.toHaveBeenCalled()
    expect(pushMock).not.toHaveBeenCalled()
    expect(sessionStorage.getItem('register_data')).toBeNull()

    await wrapper.get('#confirmPassword').setValue('secret-123')
    await wrapper.get('form').trigger('submit.prevent')
    await flushPromises()

    expect(wrapper.get('#confirmPassword').classes()).not.toContain('input-error')
    expect(verifyActionMock).toHaveBeenCalledOnce()
    expect(registerMock).toHaveBeenCalledWith({
      email: 'user@example.com',
      password: 'secret-123',
      turnstile_token: undefined,
      tencent_captcha_ticket: 'ticket',
      tencent_captcha_randstr: 'randstr',
      promo_code: undefined,
      invitation_code: undefined
    })
    expect(pushMock).toHaveBeenCalledWith('/dashboard')
  })

  it('sends and submits the email code inline while enforcing password confirmation', async () => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings, turnstile_enabled: false, email_verify_enabled: true
    })
    const wrapper = mountRegister()
    await flushPromises()
    await wrapper.get('#email').setValue('user@example.com')
    await wrapper.get('[data-testid="send-verify-code"]').trigger('click')
    await flushPromises()
    expect(sendVerifyCodeMock).toHaveBeenCalledWith(expect.objectContaining({ email: 'user@example.com' }))
    expect(wrapper.get('[data-testid="send-verify-code"]').attributes('disabled')).toBeDefined()
    await wrapper.get('#password').setValue('secret-123')
    await wrapper.get('#verify_code').setValue('123456')
    await wrapper.get('#affiliate_code').setValue('REF123')
    await wrapper.get('#confirmPassword').setValue('different-password')
    await wrapper.get('form').trigger('submit.prevent')
    await flushPromises()
    expect(registerMock).not.toHaveBeenCalled()
    await wrapper.get('#confirmPassword').setValue('secret-123')
    await wrapper.get('form').trigger('submit.prevent')
    await flushPromises()
    expect(registerMock).toHaveBeenCalledWith(expect.objectContaining({
      email: 'user@example.com', password: 'secret-123', verify_code: '123456', aff_code: 'REF123'
    }))
    expect(sessionStorage.getItem('register_data')).toBeNull()
    expect(pushMock).toHaveBeenCalledWith('/dashboard')
    expect(pushMock).not.toHaveBeenCalledWith('/email-verify')
  })

  it.each(['', '12345', 'abcdef'])('rejects invalid email code %j before registration', async (code) => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings, turnstile_enabled: false, email_verify_enabled: true
    })
    const wrapper = mountRegister()
    await flushPromises()
    await wrapper.get('#email').setValue('user@example.com')
    await wrapper.get('#password').setValue('secret-123')
    await wrapper.get('#confirmPassword').setValue('secret-123')
    await wrapper.get('#verify_code').setValue(code)
    await wrapper.get('form').trigger('submit.prevent')
    await flushPromises()
    expect(registerMock).not.toHaveBeenCalled()
    expect(wrapper.get('#verify_code').classes()).toContain('input-error')
  })

  it.each(['turnstile', 'tencent', 'aliyun'])('consumes %s captcha only on email send', async (provider) => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings, email_verify_enabled: true,
      turnstile_enabled: provider === 'turnstile',
      tencent_captcha_enabled: provider === 'tencent', tencent_captcha_app_id: 'app-id',
      aliyun_captcha_enabled: provider === 'aliyun', aliyun_captcha_scene_id: 'scene', aliyun_captcha_prefix: 'prefix'
    })
    const wrapper = mountRegister()
    await flushPromises()
    await wrapper.get('#email').setValue('user@example.com')
    if (provider === 'turnstile') {
      wrapper.findComponent({ name: 'TurnstileWidget' }).vm.$emit('verify', 'ticket')
      await flushPromises()
    }
    await wrapper.get('[data-testid="send-verify-code"]').trigger('click')
    await flushPromises()
    expect(sendVerifyCodeMock).toHaveBeenCalledWith(expect.objectContaining(provider === 'tencent'
      ? { tencent_captcha_ticket: 'ticket', tencent_captcha_randstr: 'randstr' }
      : { turnstile_token: 'ticket' }))
    expect(wrapper.get('button[type="submit"]').attributes('disabled')).toBeUndefined()
    await wrapper.get('#password').setValue('secret-123')
    await wrapper.get('#confirmPassword').setValue('secret-123')
    await wrapper.get('#verify_code').setValue('123456')
    await wrapper.get('form').trigger('submit.prevent')
    await flushPromises()
    expect(verifyActionMock).toHaveBeenCalledTimes(provider === 'turnstile' ? 0 : 1)
    expect(registerMock).toHaveBeenCalledWith(expect.objectContaining({
      verify_code: '123456', turnstile_token: undefined,
      tencent_captcha_ticket: undefined, tencent_captcha_randstr: undefined
    }))
  })

  it('allows retry after send failure and clears the code when the email changes', async () => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings, turnstile_enabled: false, email_verify_enabled: true
    })
    sendVerifyCodeMock.mockRejectedValueOnce(new Error('SMTP unavailable'))
    const wrapper = mountRegister()
    await flushPromises()
    await wrapper.get('#email').setValue('user@example.com')
    await wrapper.get('[data-testid="send-verify-code"]').trigger('click')
    await flushPromises()
    expect(showErrorMock).toHaveBeenCalled()
    expect(wrapper.get('[data-testid="send-verify-code"]').attributes('disabled')).toBeUndefined()
    await wrapper.get('[data-testid="send-verify-code"]').trigger('click')
    await flushPromises()
    expect(sendVerifyCodeMock).toHaveBeenCalledTimes(2)
    await wrapper.get('#verify_code').setValue('123456')
    await wrapper.get('#email').setValue('other@example.com')
    expect((wrapper.get('#verify_code').element as HTMLInputElement).value).toBe('')
  })

  it.each([false, true])('respects domain quota mode %j when sending email', async (quotaEnabled) => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings, turnstile_enabled: false, email_verify_enabled: true,
      registration_email_suffix_whitelist: ['allowed.com'],
      registration_email_domain_quota_enabled: quotaEnabled
    })
    const wrapper = mountRegister()
    await flushPromises()
    await wrapper.get('#email').setValue('user@custom.example')
    await wrapper.get('[data-testid="send-verify-code"]').trigger('click')
    await flushPromises()
    expect(sendVerifyCodeMock).toHaveBeenCalledTimes(quotaEnabled ? 1 : 0)
  })

  it('keeps the optional affiliate invitation field before Turnstile', async () => {
    const wrapper = mountRegister()
    await flushPromises()

    const invitationField = wrapper.get('[data-testid="affiliate-invitation-field"]')
    const turnstile = wrapper.get('[data-testid="registration-turnstile"]')

    expect(invitationField.get('input').attributes('id')).toBe('affiliate_code')
    expect(invitationField.text()).toContain('common.optional')
    expect(
      invitationField.element.compareDocumentPosition(turnstile.element) &
        Node.DOCUMENT_POSITION_FOLLOWING
    ).toBeTruthy()
  })

  it('uses the mandatory invitation field without duplicating the affiliate field', async () => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings,
      invitation_code_enabled: true
    })

    const wrapper = mountRegister()
    await flushPromises()

    expect(wrapper.find('[data-testid="affiliate-invitation-field"]').exists()).toBe(false)
    expect(wrapper.get('#invitation_code').exists()).toBe(true)
  })

  it('submits a non-whitelist email domain so the backend can enforce its registration quota', async () => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings,
      turnstile_enabled: false,
      registration_email_suffix_whitelist: ['allowed.com'],
      registration_email_domain_quota_enabled: true
    })

    const wrapper = mountRegister()
    await flushPromises()
    await wrapper.get('#email').setValue('first@custom.example')
    await wrapper.get('#password').setValue('secret-123')
    await wrapper.get('#confirmPassword').setValue('secret-123')
    await wrapper.get('form').trigger('submit.prevent')
    await flushPromises()

    expect(registerMock).toHaveBeenCalledWith(
      expect.objectContaining({ email: 'first@custom.example' })
    )
    expect(showErrorMock).not.toHaveBeenCalled()
  })

  it('shows the localized registration domain quota message returned by the backend', async () => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings,
      turnstile_enabled: false,
      registration_email_suffix_whitelist: ['allowed.com'],
      registration_email_domain_quota_enabled: true
    })
    registerMock.mockRejectedValueOnce({
      reason: 'EMAIL_DOMAIN_REGISTRATION_LIMIT',
      message: 'raw backend message'
    })

    const wrapper = mountRegister()
    await flushPromises()
    await wrapper.get('#email').setValue('second@custom.example')
    await wrapper.get('#password').setValue('secret-123')
    await wrapper.get('#confirmPassword').setValue('secret-123')
    await wrapper.get('form').trigger('submit.prevent')
    await flushPromises()

    expect(showErrorMock).toHaveBeenCalledWith(
      '该邮箱域名无法注册新账户。请使用主流邮箱注册；如需使用企业邮箱，请联系客服添加域名白名单。'
    )
  })

  // 域名限量注册开关默认关闭：恢复 PR5423 之前的客户端白名单预检，非白名单域名不发起注册请求。
  it('rejects a non-whitelist email domain locally when the domain quota switch is disabled', async () => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings,
      turnstile_enabled: false,
      registration_email_suffix_whitelist: ['allowed.com']
    })

    const wrapper = mountRegister()
    await flushPromises()
    await wrapper.get('#email').setValue('first@custom.example')
    await wrapper.get('#password').setValue('secret-123')
    await wrapper.get('#confirmPassword').setValue('secret-123')
    await wrapper.get('form').trigger('submit.prevent')
    await flushPromises()

    expect(registerMock).not.toHaveBeenCalled()
    // 校验失败通过 validationToastMessage watcher 弹 toast
    expect(showErrorMock).toHaveBeenCalledWith('auth.emailSuffixNotAllowedWithAllowed')
    expect(wrapper.get('#email').classes()).toContain('input-error')
  })

  it('still submits whitelisted email domains when the domain quota switch is disabled', async () => {
    getPublicSettingsMock.mockResolvedValueOnce({
      ...publicSettings,
      turnstile_enabled: false,
      registration_email_suffix_whitelist: ['allowed.com']
    })

    const wrapper = mountRegister()
    await flushPromises()
    await wrapper.get('#email').setValue('user@allowed.com')
    await wrapper.get('#password').setValue('secret-123')
    await wrapper.get('#confirmPassword').setValue('secret-123')
    await wrapper.get('form').trigger('submit.prevent')
    await flushPromises()

    expect(registerMock).toHaveBeenCalledWith(
      expect.objectContaining({ email: 'user@allowed.com' })
    )
    expect(showErrorMock).not.toHaveBeenCalled()
  })
})
