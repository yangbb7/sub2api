import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { describe, expect, it, vi } from 'vitest'
import LegalDocumentView from '@/views/public/LegalDocumentView.vue'

const getPublicSettingsMock = vi.fn()

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRoute: () => ({
      params: { documentId: 'security-privacy' },
    }),
  }
})

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string) => key,
    }),
  }
})

vi.mock('@/api/auth', async () => {
  const actual = await vi.importActual<typeof import('@/api/auth')>('@/api/auth')
  return {
    ...actual,
    getPublicSettings: (...args: any[]) => getPublicSettingsMock(...args),
  }
})

describe('LegalDocumentView security statement', () => {
  it('renders the security privacy document as a public security statement', async () => {
    const pinia = createPinia()
    setActivePinia(pinia)
    getPublicSettingsMock.mockResolvedValue({
      site_name: 'AI Gateway',
      site_logo: '',
      login_agreement_updated_at: '2026-06-11',
      login_agreement_documents: [
        {
          id: 'security-privacy',
          title: '安全与隐私声明',
          content_md: '## 请求内容如何处理\n\n不保存 prompt 或 response 正文。',
        },
      ],
    })

    const wrapper = mount(LegalDocumentView, {
      global: {
        plugins: [pinia],
        stubs: {
          RouterLink: {
            props: ['to'],
            template: '<a :href="to"><slot /></a>',
          },
          Icon: true,
        },
      },
    })

    await flushPromises()

    expect(wrapper.text()).toContain('安全与隐私声明')
    expect(wrapper.text()).toContain('请求内容如何处理')
    expect(wrapper.text()).toContain('不保存 prompt 或 response 正文。')
    expect(wrapper.text()).not.toContain('登录条款')
  })
})
