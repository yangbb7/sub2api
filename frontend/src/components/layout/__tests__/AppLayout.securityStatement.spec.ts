import { flushPromises, mount } from '@vue/test-utils'
import { computed, reactive } from 'vue'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import AppLayout from '@/components/layout/AppLayout.vue'
import SecurityStatementModal from '@/components/layout/SecurityStatementModal.vue'

const appState = reactive({
  sidebarCollapsed: false,
  cachedPublicSettings: {
    login_agreement_revision: 'rev-1',
    login_agreement_documents: [
      {
        id: 'security-privacy',
        title: '安全与隐私声明',
        content_md: '## 请求内容如何处理\n\n不保存 prompt 或 response 正文。',
      },
    ],
  },
})

const authState = reactive({
  user: {
    id: 7,
    email: 'user@example.com',
    role: 'user',
  },
})

vi.mock('@/stores', () => ({
  useAppStore: () => appState,
}))

vi.mock('@/stores/auth', () => ({
  useAuthStore: () => authState,
}))

vi.mock('@/composables/useOnboardingTour', () => ({
  useOnboardingTour: () => ({
    replayTour: vi.fn(),
  }),
}))

vi.mock('@/stores/onboarding', () => ({
  useOnboardingStore: () => ({
    setReplayCallback: vi.fn(),
  }),
}))

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  const messages: Record<string, string> = {
    'securityStatementModal.title': '安全与隐私声明',
    'securityStatementModal.noticeTitle': '继续使用前，请先阅读这份安全与隐私说明。',
    'securityStatementModal.noticeBody': '平台会处理账号、API Key、余额、用量和必要审计数据；API 请求会按调度规则转发到上游模型服务。',
    'securityStatementModal.openFullStatement': '打开完整声明页面',
    'securityStatementModal.acknowledge': '我已了解，继续使用',
  }
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string) => messages[key] ?? key,
    }),
  }
})

const RouterLinkStub = {
  props: ['to'],
  template: '<a :href="typeof to === `string` ? to : `/legal/${to.params.documentId}`"><slot /></a>',
}

function mountLayout() {
  return mount(AppLayout, {
    slots: {
      default: '<div>Dashboard content</div>',
    },
    global: {
      stubs: {
        AppSidebar: true,
        AppHeader: true,
        RouterLink: RouterLinkStub,
        Teleport: true,
        transition: false,
      },
    },
  })
}

async function closeWrapper(wrapper: ReturnType<typeof mountLayout>) {
  wrapper.unmount()
  await flushPromises()
}

describe('AppLayout security statement modal', () => {
  beforeEach(() => {
    localStorage.clear()
    appState.cachedPublicSettings = {
      login_agreement_revision: 'rev-1',
      login_agreement_documents: [
        {
          id: 'security-privacy',
          title: '安全与隐私声明',
          content_md: '## 请求内容如何处理\n\n不保存 prompt 或 response 正文。',
        },
      ],
    }
    authState.user = {
      id: 7,
      email: 'user@example.com',
      role: 'user',
    }
  })

  it('shows the security statement after login until the user acknowledges the current revision', async () => {
    const wrapper = mountLayout()

    await flushPromises()

    expect(wrapper.text()).toContain('安全与隐私声明')
    expect(wrapper.text()).toContain('不保存 prompt 或 response 正文')
    expect(wrapper.findComponent(SecurityStatementModal).props('visible')).toBe(true)

    await wrapper.get('[data-testid="security-statement-acknowledge"]').trigger('click')
    await flushPromises()

    expect(wrapper.findComponent(SecurityStatementModal).props('visible')).toBe(false)
    expect(wrapper.text()).not.toContain('继续使用前，请先阅读这份安全与隐私说明。')
    expect(localStorage.getItem('gateway_security_statement_ack:user:7:rev-1')).toBe('1')

    await closeWrapper(wrapper)
  })

  it('does not show again once the same user has acknowledged the same revision', async () => {
    localStorage.setItem('gateway_security_statement_ack:user:7:rev-1', '1')

    const wrapper = mountLayout()

    await flushPromises()

    expect(wrapper.findComponent(SecurityStatementModal).props('visible')).toBe(false)
    expect(wrapper.text()).not.toContain('继续使用前，请先阅读这份安全与隐私说明。')

    await closeWrapper(wrapper)
  })
})
