import { flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import AppLayout from '@/components/layout/AppLayout.vue'

const replayTourMock = vi.fn()
const setReplayCallbackMock = vi.fn()

const appStoreState = {
  sidebarCollapsed: false,
  cachedPublicSettings: {
    login_agreement_revision: 'rev-1',
    login_agreement_updated_at: '2026-06-11',
    login_agreement_documents: [
      {
        id: 'security-privacy',
        title: '安全与隐私声明',
        content_md: '## 请求内容如何处理\n\n平台会转发你的 API 请求。',
      },
    ],
  },
}

const authStoreState = {
  user: {
    id: 7,
    email: 'user@example.com',
    role: 'user',
  },
}

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string) => {
        const messages: Record<string, string> = {
          'securityStatementModal.summary':
            '使用本服务前，请确认你已了解请求转发、数据处理和合规使用要求。',
          'securityStatementModal.openFullStatement': '查看完整声明',
          'securityStatementModal.acknowledge': '我已了解，继续',
        }
        return messages[key] || key
      },
    }),
  }
})

vi.mock('@/stores', () => ({
  useAppStore: () => appStoreState,
}))

vi.mock('@/stores/auth', () => ({
  useAuthStore: () => authStoreState,
}))

vi.mock('@/stores/onboarding', () => ({
  useOnboardingStore: () => ({
    setReplayCallback: setReplayCallbackMock,
  }),
}))

vi.mock('@/composables/useOnboardingTour', () => ({
  useOnboardingTour: () => ({
    replayTour: replayTourMock,
  }),
}))

describe('AppLayout security statement modal', () => {
  beforeEach(() => {
    window.localStorage.clear()
    document.body.innerHTML = ''
    vi.clearAllMocks()
  })

  afterEach(() => {
    document.body.innerHTML = ''
    document.body.className = ''
  })

  it('shows the security statement after login and stores acknowledgement by user and revision', async () => {
    const wrapper = mount(AppLayout, {
      attachTo: document.body,
      global: {
        stubs: {
          AppSidebar: true,
          AppHeader: true,
          Icon: true,
          RouterLink: {
            props: ['to'],
            template: '<a href="#"><slot /></a>',
          },
          Teleport: true,
        },
      },
    })

    await flushPromises()

    expect(document.body.textContent).toContain('安全与隐私声明')
    expect(document.body.textContent).toContain('请求内容如何处理')
    expect(document.body.textContent).toContain('平台会转发你的 API 请求。')

    await wrapper.get('button[data-testid="security-statement-ack"]').trigger('click')

    expect(document.body.textContent).not.toContain('安全与隐私声明')
    expect(window.localStorage.getItem('gateway_security_statement_ack:user-7:rev-1')).toBe('1')
  })

  it('does not show the security statement after the same revision was acknowledged', async () => {
    window.localStorage.setItem('gateway_security_statement_ack:user-7:rev-1', '1')

    mount(AppLayout, {
      attachTo: document.body,
      global: {
        stubs: {
          AppSidebar: true,
          AppHeader: true,
          Icon: true,
          RouterLink: {
            props: ['to'],
            template: '<a href="#"><slot /></a>',
          },
          Teleport: true,
        },
      },
    })

    await flushPromises()

    expect(document.body.textContent).not.toContain('安全与隐私声明')
  })
})
