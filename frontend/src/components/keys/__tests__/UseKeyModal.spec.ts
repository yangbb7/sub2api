import { describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key: string) => key
  })
}))

vi.mock('@/composables/useClipboard', () => ({
  useClipboard: () => ({
    copyToClipboard: vi.fn().mockResolvedValue(true)
  })
}))

import UseKeyModal from '../UseKeyModal.vue'

describe('UseKeyModal', () => {
  it('adds the OpenAI /v1 suffix for Codex CLI config', () => {
    const wrapper = mount(UseKeyModal, {
      props: {
        show: true,
        apiKey: 'sk-test',
        baseUrl: 'https://api.braintech.icu',
        platform: 'openai'
      },
      global: {
        stubs: {
          BaseDialog: {
            template: '<div><slot /><slot name="footer" /></div>'
          },
          Icon: {
            template: '<span />'
          }
        }
      }
    })

    const codeBlock = wrapper.find('pre code')
    expect(codeBlock.exists()).toBe(true)
    expect(codeBlock.text()).toContain('base_url = "https://api.braintech.icu/v1"')
    expect(codeBlock.text()).not.toContain('base_url = "https://api.braintech.icu"')
  })

  it('does not duplicate the OpenAI /v1 suffix for Codex CLI config', () => {
    const wrapper = mount(UseKeyModal, {
      props: {
        show: true,
        apiKey: 'sk-test',
        baseUrl: 'https://api.braintech.icu/v1',
        platform: 'openai'
      },
      global: {
        stubs: {
          BaseDialog: {
            template: '<div><slot /><slot name="footer" /></div>'
          },
          Icon: {
            template: '<span />'
          }
        }
      }
    })

    const codeBlock = wrapper.find('pre code')
    expect(codeBlock.text()).toContain('base_url = "https://api.braintech.icu/v1"')
    expect(codeBlock.text()).not.toContain('/v1/v1')
  })

  it('falls back to the current origin with /v1 when API base URL is empty', () => {
    const originalLocation = window.location
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: {
        ...originalLocation,
        origin: 'https://api.braintech.icu'
      }
    })

    try {
      const wrapper = mount(UseKeyModal, {
        props: {
          show: true,
          apiKey: 'sk-test',
          baseUrl: '',
          platform: 'openai'
        },
        global: {
          stubs: {
            BaseDialog: {
              template: '<div><slot /><slot name="footer" /></div>'
            },
            Icon: {
              template: '<span />'
            }
          }
        }
      })

      const codeBlock = wrapper.find('pre code')
      expect(codeBlock.text()).toContain('base_url = "https://api.braintech.icu/v1"')
      expect(codeBlock.text()).not.toContain('base_url = "https://api.braintech.icu"')
    } finally {
      Object.defineProperty(window, 'location', {
        configurable: true,
        value: originalLocation
      })
    }
  })

  it('renders GPT-5.4 mini entry in OpenCode config', async () => {
    const wrapper = mount(UseKeyModal, {
      props: {
        show: true,
        apiKey: 'sk-test',
        baseUrl: 'https://example.com/v1',
        platform: 'openai'
      },
      global: {
        stubs: {
          BaseDialog: {
            template: '<div><slot /><slot name="footer" /></div>'
          },
          Icon: {
            template: '<span />'
          }
        }
      }
    })

    const opencodeTab = wrapper.findAll('button').find((button) =>
      button.text().includes('keys.useKeyModal.cliTabs.opencode')
    )

    expect(opencodeTab).toBeDefined()
    await opencodeTab!.trigger('click')
    await nextTick()

    const codeBlock = wrapper.find('pre code')
    expect(codeBlock.exists()).toBe(true)
    expect(codeBlock.text()).toContain('"name": "GPT-5.4 Mini"')
    expect(codeBlock.text()).not.toContain('"name": "GPT-5.4 Nano"')
  })
})
