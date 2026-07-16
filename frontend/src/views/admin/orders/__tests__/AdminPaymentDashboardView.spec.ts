import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'

const { getDashboard, showError } = vi.hoisted(() => ({
  getDashboard: vi.fn(),
  showError: vi.fn(),
}))

vi.mock('vue-i18n', async (importOriginal) => ({
  ...(await importOriginal<typeof import('vue-i18n')>()),
  useI18n: () => ({ t: (key: string) => key }),
}))

vi.mock('@/stores/app', () => ({
  useAppStore: () => ({ showError }),
}))

vi.mock('@/api/admin/payment', () => {
  const api = { getDashboard }
  return { adminPaymentAPI: api, default: api }
})

import AdminPaymentDashboardView from '../AdminPaymentDashboardView.vue'
import OrderStatsCards from '@/components/admin/payment/OrderStatsCards.vue'

const stats = {
  today_amount: 10,
  total_amount: 120.5,
  today_count: 1,
  total_count: 7,
  avg_amount: 17.21,
  pending_orders: 2,
  daily_series: [],
  payment_methods: [],
  top_users: [],
}

const AppLayoutStub = { template: '<div><slot /></div>' }
const DateRangePickerStub = {
  props: ['startDate', 'endDate'],
  emits: ['update:startDate', 'update:endDate', 'change'],
  template: `
    <button
      data-testid="dashboard-date-range"
      @click="$emit('change', { startDate: '2026-05-01', endDate: '2026-05-15', preset: null })"
    />
  `,
}

describe('AdminPaymentDashboardView', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-07-16T12:00:00+08:00'))
    getDashboard.mockReset()
    getDashboard.mockResolvedValue({ data: stats })
    showError.mockReset()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('loads the latest 30 calendar days and supports a custom range', async () => {
    const wrapper = mount(AdminPaymentDashboardView, {
      global: {
        stubs: {
          AppLayout: AppLayoutStub,
          DateRangePicker: DateRangePickerStub,
          LoadingSpinner: true,
          Icon: true,
          OrderStatsCards: true,
          DailyRevenueChart: true,
        },
      },
    })
    await flushPromises()

    expect(getDashboard).toHaveBeenNthCalledWith(1, {
      start_date: '2026-06-17',
      end_date: '2026-07-16',
    })

    await wrapper.get('[data-testid="dashboard-date-range"]').trigger('click')
    await flushPromises()

    expect(getDashboard).toHaveBeenNthCalledWith(2, {
      start_date: '2026-05-01',
      end_date: '2026-05-15',
    })
  })

  it('renders range-scoped cards including pending orders', () => {
    const wrapper = mount(OrderStatsCards, {
      props: { stats },
      global: { stubs: { Icon: true } },
    })

    expect(wrapper.text()).toContain('payment.admin.rangeRevenue')
    expect(wrapper.text()).toContain('payment.admin.rangeOrders')
    expect(wrapper.text()).toContain('payment.admin.rangeAvgAmount')
    expect(wrapper.text()).toContain('payment.admin.rangePendingOrders')
    expect(wrapper.text()).not.toContain('payment.admin.todayRevenue')
    expect(wrapper.text()).not.toContain('payment.admin.todayOrders')
  })

  it('keeps the newest dashboard response when requests finish out of order', async () => {
    const wrapper = mount(AdminPaymentDashboardView, {
      global: {
        stubs: {
          AppLayout: AppLayoutStub,
          DateRangePicker: DateRangePickerStub,
          LoadingSpinner: true,
          Icon: true,
          OrderStatsCards: true,
          DailyRevenueChart: true,
        },
      },
    })
    await flushPromises()

    let resolveOlder!: (value: unknown) => void
    let resolveNewer!: (value: unknown) => void
    const older = new Promise((resolve) => { resolveOlder = resolve })
    const newer = new Promise((resolve) => { resolveNewer = resolve })
    getDashboard
      .mockImplementationOnce(() => older)
      .mockImplementationOnce(() => newer)

    const olderRequest = (wrapper.vm as any).loadDashboard()
    const newerRequest = (wrapper.vm as any).loadDashboard()
    resolveNewer({ data: { ...stats, total_count: 22 } })
    await flushPromises()
    resolveOlder({ data: { ...stats, total_count: 11 } })
    await Promise.all([olderRequest, newerRequest])

    expect((wrapper.vm as any).stats.total_count).toBe(22)
    expect((wrapper.vm as any).loading).toBe(false)
  })
})
