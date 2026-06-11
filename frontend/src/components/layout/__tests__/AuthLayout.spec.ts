import { flushPromises, mount } from '@vue/test-utils'
import { describe, expect, it, vi } from 'vitest'
import AuthLayout from '@/components/layout/AuthLayout.vue'

const fetchPublicSettingsMock = vi.fn()

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string) => (key === 'home.securityStatement' ? '安全声明' : key),
    }),
  }
})

vi.mock('@/stores', () => ({
  useAppStore: () => ({
    siteName: 'AI Gateway',
    siteLogo: '',
    cachedPublicSettings: {
      site_subtitle: 'AI API Gateway Platform',
      login_agreement_documents: [
        {
          id: 'security-privacy',
          title: '安全与隐私声明',
          content_md: '## 请求内容如何处理',
        },
      ],
    },
    fetchPublicSettings: fetchPublicSettingsMock,
  }),
}))

describe('AuthLayout security statement link', () => {
  it('renders a public security statement link in the auth footer', async () => {
    const wrapper = mount(AuthLayout, {
      global: {
        stubs: {
          RouterLink: {
            props: ['to'],
            template: '<a :href="to"><slot /></a>',
          },
        },
      },
    })

    await flushPromises()

    const link = wrapper.get('a[href="/legal/security-privacy"]')
    expect(link.text()).toBe('安全声明')
    expect(fetchPublicSettingsMock).toHaveBeenCalled()
  })
})
