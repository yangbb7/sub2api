import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { ref } from 'vue'

import DateRangePicker from '../DateRangePicker.vue'

const componentPath = resolve(dirname(fileURLToPath(import.meta.url)), '../DateRangePicker.vue')
const componentSource = readFileSync(componentPath, 'utf8')

const messages: Record<string, string> = {
  'dates.allTime': 'All Time',
  'dates.today': 'Today',
  'dates.yesterday': 'Yesterday',
  'dates.last24Hours': 'Last 24 Hours',
  'dates.last7Days': 'Last 7 Days',
  'dates.last14Days': 'Last 14 Days',
  'dates.last30Days': 'Last 30 Days',
  'dates.thisMonth': 'This Month',
  'dates.lastMonth': 'Last Month',
  'dates.startDate': 'Start Date',
  'dates.endDate': 'End Date',
  'dates.apply': 'Apply',
  'dates.selectDateRange': 'Select date range'
}

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key: string) => messages[key] ?? key,
    locale: ref('en')
  })
}))

const formatLocalDate = (date: Date): string => {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

const setViewportWidth = (width: number) => {
  Object.defineProperty(window, 'innerWidth', {
    configurable: true,
    value: width
  })
}

const mockElementRect = (left: number): DOMRect => ({
  x: left,
  y: 0,
  width: 100,
  height: 40,
  top: 0,
  right: left + 100,
  bottom: 40,
  left,
  toJSON: () => ({})
})

const getDropdownViewportLeft = (wrapper: ReturnType<typeof mount>, triggerLeft: number) => {
  const inlineLeft = Number.parseFloat(
    wrapper.get('.date-picker-dropdown').element.style.left
  )
  return triggerLeft + inlineLeft
}

describe('DateRangePicker', () => {
  const originalInnerWidth = window.innerWidth

  afterEach(() => {
    Object.defineProperty(window, 'innerWidth', {
      configurable: true,
      value: originalInnerWidth
    })
    vi.restoreAllMocks()
  })

  it('only offers all-time clearing when explicitly enabled', async () => {
    const today = formatLocalDate(new Date())
    const defaultWrapper = mount(DateRangePicker, {
      props: { startDate: today, endDate: today },
      global: { stubs: { Icon: true } }
    })

    await defaultWrapper.find('.date-picker-trigger').trigger('click')
    expect(defaultWrapper.text()).not.toContain('All Time')

    const clearableWrapper = mount(DateRangePicker, {
      props: { startDate: today, endDate: today, allowClear: true },
      global: { stubs: { Icon: true } }
    })

    await clearableWrapper.find('.date-picker-trigger').trigger('click')
    const allTimeButton = clearableWrapper.findAll('.date-picker-preset').find((node) =>
      node.text().includes('All Time')
    )
    expect(allTimeButton).toBeDefined()

    await allTimeButton!.trigger('click')
    await clearableWrapper.find('.date-picker-apply').trigger('click')

    expect(clearableWrapper.emitted('update:startDate')?.[0]).toEqual([''])
    expect(clearableWrapper.emitted('update:endDate')?.[0]).toEqual([''])
    expect(clearableWrapper.emitted('change')?.[0]).toEqual([
      { startDate: '', endDate: '', preset: 'allTime' }
    ])
  })

  it('uses last 24 hours as the default recognized preset', () => {
    const now = new Date()
    const yesterday = new Date(now.getTime() - 24 * 60 * 60 * 1000)

    const wrapper = mount(DateRangePicker, {
      props: {
        startDate: formatLocalDate(yesterday),
        endDate: formatLocalDate(now)
      },
      global: {
        stubs: {
          Icon: true
        }
      }
    })

    expect(wrapper.text()).toContain('Last 24 Hours')
  })

  it('emits range updates with last24Hours preset when applied', async () => {
    const now = new Date()
    const today = formatLocalDate(now)

    const wrapper = mount(DateRangePicker, {
      props: {
        startDate: today,
        endDate: today
      },
      global: {
        stubs: {
          Icon: true
        }
      }
    })

    await wrapper.find('.date-picker-trigger').trigger('click')
    const presetButton = wrapper.findAll('.date-picker-preset').find((node) =>
      node.text().includes('Last 24 Hours')
    )
    expect(presetButton).toBeDefined()

    await presetButton!.trigger('click')
    await wrapper.find('.date-picker-apply').trigger('click')

    const nowAfterClick = new Date()
    const yesterdayAfterClick = new Date(nowAfterClick.getTime() - 24 * 60 * 60 * 1000)
    const expectedStart = formatLocalDate(yesterdayAfterClick)
    const expectedEnd = formatLocalDate(nowAfterClick)

    expect(wrapper.emitted('update:startDate')?.[0]).toEqual([expectedStart])
    expect(wrapper.emitted('update:endDate')?.[0]).toEqual([expectedEnd])
    expect(wrapper.emitted('change')?.[0]).toEqual([
      {
        startDate: expectedStart,
        endDate: expectedEnd,
        preset: 'last24Hours'
      }
    ])
  })

  it('shifts the dropdown left when a right-aligned trigger would overflow the viewport', async () => {
    const triggerLeft = 900
    setViewportWidth(1024)
    const wrapper = mount(DateRangePicker, {
      props: {
        startDate: '2026-07-01',
        endDate: '2026-07-16'
      },
      global: { stubs: { Icon: true } }
    })
    vi.spyOn(wrapper.element, 'getBoundingClientRect').mockReturnValue(
      mockElementRect(triggerLeft)
    )

    await wrapper.find('.date-picker-trigger').trigger('click')

    const dropdownLeft = getDropdownViewportLeft(wrapper, triggerLeft)
    expect(dropdownLeft).toBeGreaterThanOrEqual(12)
    expect(dropdownLeft + 320).toBeLessThanOrEqual(1024 - 12)

    setViewportWidth(1280)
    window.dispatchEvent(new Event('resize'))
    await wrapper.vm.$nextTick()

    const resizedDropdownLeft = getDropdownViewportLeft(wrapper, triggerLeft)
    expect(resizedDropdownLeft).toBeGreaterThanOrEqual(12)
    expect(resizedDropdownLeft + 320).toBeLessThanOrEqual(1280 - 12)
  })

  it.each([
    { viewportWidth: 320, triggerLeft: 260 },
    { viewportWidth: 1024, triggerLeft: 4 }
  ])(
    'keeps the dropdown inside both viewport gutters at $viewportWidth px',
    async ({ viewportWidth, triggerLeft }) => {
      setViewportWidth(viewportWidth)
      const wrapper = mount(DateRangePicker, {
        props: {
          startDate: '2026-07-01',
          endDate: '2026-07-16'
        },
        global: { stubs: { Icon: true } }
      })
      vi.spyOn(wrapper.element, 'getBoundingClientRect').mockReturnValue(
        mockElementRect(triggerLeft)
      )

      await wrapper.find('.date-picker-trigger').trigger('click')

      const dropdownWidth = Math.min(320, viewportWidth - 24)
      const dropdownLeft = getDropdownViewportLeft(wrapper, triggerLeft)
      expect(dropdownLeft).toBeGreaterThanOrEqual(12)
      expect(dropdownLeft + dropdownWidth).toBeLessThanOrEqual(viewportWidth - 12)
    }
  )

  it('keeps the dropdown and date fields shrinkable on narrow viewports', () => {
    expect(componentSource).toContain('width: min(320px, calc(100vw - 24px));')
    expect(componentSource).toContain('max-width: calc(100vw - 24px);')
    expect(componentSource).not.toContain('@apply min-w-[320px]')
    expect(componentSource).toContain('@apply min-w-0 flex-1;')
    expect(componentSource).toContain('@apply min-w-0 w-full max-w-full')
    expect(componentSource).toContain('@media (max-width: 359px)')
  })
})
