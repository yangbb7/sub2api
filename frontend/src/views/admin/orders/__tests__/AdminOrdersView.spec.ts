import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'

const {
  getOrders,
  exportOrders,
  showSuccess,
  showWarning,
  showError,
} = vi.hoisted(() => ({
  getOrders: vi.fn(),
  exportOrders: vi.fn(),
  showSuccess: vi.fn(),
  showWarning: vi.fn(),
  showError: vi.fn(),
}))

vi.mock('vue-i18n', async (importOriginal) => ({
  ...(await importOriginal<typeof import('vue-i18n')>()),
  useI18n: () => ({ t: (key: string) => key }),
}))

vi.mock('@/stores/app', () => ({
  useAppStore: () => ({ showSuccess, showWarning, showError }),
}))

vi.mock('@/utils/apiError', () => ({
  extractI18nErrorMessage: (
    _error: unknown,
    _t: unknown,
    _prefix: string,
    fallback: string,
  ) => fallback,
}))

vi.mock('@/api/admin/payment', () => {
  const api = {
    getOrders,
    exportOrders,
    getOrder: vi.fn(),
    cancelOrder: vi.fn(),
    retryRecharge: vi.fn(),
    refundOrder: vi.fn(),
    queryRefund: vi.fn(),
  }
  return { adminPaymentAPI: api, default: api }
})

import AdminOrdersView from '../AdminOrdersView.vue'

const AppLayoutStub = { template: '<div><slot /></div>' }
const DateRangePickerStub = {
  props: {
    startDate: { type: String, default: '' },
    endDate: { type: String, default: '' },
    allowClear: Boolean,
  },
  emits: ['update:startDate', 'update:endDate', 'change'],
  template: `
    <div>
      <button
        data-testid="orders-date-range"
        :data-allow-clear="String(allowClear)"
        @click="$emit('change', { startDate: '2026-06-01', endDate: '2026-06-30', preset: null })"
      />
      <button
        data-testid="orders-clear-date-range"
        @click="$emit('change', { startDate: '', endDate: '', preset: 'allTime' })"
      />
    </div>
  `,
}

function mountView() {
  return mount(AdminOrdersView, {
    global: {
      stubs: {
        AppLayout: AppLayoutStub,
        DateRangePicker: DateRangePickerStub,
        Select: true,
        Icon: true,
        OrderTable: true,
        Pagination: true,
        BaseDialog: { template: '<div><slot /></div>' },
        AdminRefundDialog: true,
        OrderStatusBadge: true,
      },
    },
  })
}

describe('AdminOrdersView', () => {
  beforeEach(() => {
    getOrders.mockReset()
    getOrders.mockResolvedValue({
      data: { items: [], total: 1, page: 1, page_size: 20, pages: 1 },
    })
    exportOrders.mockReset()
    showSuccess.mockReset()
    showWarning.mockReset()
    showError.mockReset()
    Object.defineProperty(window.URL, 'createObjectURL', {
      configurable: true,
      value: vi.fn(() => 'blob:orders-export'),
    })
    Object.defineProperty(window.URL, 'revokeObjectURL', {
      configurable: true,
      value: vi.fn(),
    })
  })

  it('resets pagination and combines the selected dates with every list filter', async () => {
    const wrapper = mountView()
    await flushPromises()

    expect(wrapper.get('[data-testid="orders-date-range"]').attributes('data-allow-clear')).toBe('true')

    ;(wrapper.vm as any).orderSearch = 'customer@example.com'
    ;(wrapper.vm as any).orderFilters.status = 'COMPLETED'
    ;(wrapper.vm as any).orderFilters.payment_type = 'stripe'
    ;(wrapper.vm as any).orderFilters.order_type = 'subscription'
    ;(wrapper.vm as any).orderPagination.page = 4

    await wrapper.get('[data-testid="orders-date-range"]').trigger('click')
    await flushPromises()

    expect(getOrders).toHaveBeenLastCalledWith({
      page: 1,
      page_size: 20,
      keyword: 'customer@example.com',
      status: 'COMPLETED',
      payment_type: 'stripe',
      order_type: 'subscription',
      start_date: '2026-06-01',
      end_date: '2026-06-30',
    })

    ;(wrapper.vm as any).orderPagination.page = 3
    await wrapper.get('[data-testid="orders-clear-date-range"]').trigger('click')
    await flushPromises()

    expect(getOrders).toHaveBeenLastCalledWith({
      page: 1,
      page_size: 20,
      keyword: 'customer@example.com',
      status: 'COMPLETED',
      payment_type: 'stripe',
      order_type: 'subscription',
      start_date: undefined,
      end_date: undefined,
    })
  })

  it('downloads the server CSV with current filters and server filename', async () => {
    const wrapper = mountView()
    await flushPromises()
    ;(wrapper.vm as any).orderFilters.status = 'PAID'
    ;(wrapper.vm as any).startDate = '2026-07-01'
    ;(wrapper.vm as any).endDate = '2026-07-16'

    exportOrders.mockResolvedValue({
      data: new Blob(['order_id,status\n1,PAID\n'], { type: 'text/csv' }),
      headers: {
        'content-disposition': 'attachment; filename="orders-server.csv"',
        'x-export-count': '1',
      },
    })
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})

    await wrapper.get('[data-testid="export-orders"]').trigger('click')
    await flushPromises()

    expect(exportOrders).toHaveBeenCalledWith({
      keyword: undefined,
      status: 'PAID',
      payment_type: undefined,
      order_type: undefined,
      start_date: '2026-07-01',
      end_date: '2026-07-16',
    })
    expect(click).toHaveBeenCalledOnce()
    expect((click.mock.instances[0] as HTMLAnchorElement).download).toBe('orders-server.csv')
    expect(window.URL.createObjectURL).toHaveBeenCalledOnce()
    expect(window.URL.revokeObjectURL).toHaveBeenCalledWith('blob:orders-export')
    expect(showSuccess).toHaveBeenCalledWith('payment.admin.exportOrdersSuccess')
    expect((wrapper.vm as any).exportingOrders).toBe(false)
  })

  it('uses the server export count when no orders match', async () => {
    exportOrders.mockResolvedValueOnce({
      data: new Blob(['id\n'], { type: 'text/csv' }),
      headers: { 'x-export-count': '0' },
    })
    const wrapper = mountView()
    await flushPromises()

    await wrapper.get('[data-testid="export-orders"]').trigger('click')
    await flushPromises()

    expect(exportOrders).toHaveBeenCalledOnce()
    expect(showWarning).toHaveBeenCalledWith('payment.admin.noOrdersToExport')
    expect(window.URL.createObjectURL).not.toHaveBeenCalled()
    expect(showSuccess).not.toHaveBeenCalled()
  })

  it('restores the export action and reports download failures', async () => {
    exportOrders.mockRejectedValueOnce(new Error('network failure'))
    const wrapper = mountView()
    await flushPromises()

    await wrapper.get('[data-testid="export-orders"]').trigger('click')
    await flushPromises()

    expect(showError).toHaveBeenCalledWith('payment.admin.exportOrdersFailed')
    expect((wrapper.vm as any).exportingOrders).toBe(false)
    expect(wrapper.get('[data-testid="export-orders"]').attributes('disabled')).toBeUndefined()
  })

  it('keeps the newest order response when requests finish out of order', async () => {
    const wrapper = mountView()
    await flushPromises()

    let resolveOlder!: (value: unknown) => void
    let resolveNewer!: (value: unknown) => void
    const older = new Promise((resolve) => { resolveOlder = resolve })
    const newer = new Promise((resolve) => { resolveNewer = resolve })
    getOrders
      .mockImplementationOnce(() => older)
      .mockImplementationOnce(() => newer)

    const olderRequest = (wrapper.vm as any).loadOrders()
    const newerRequest = (wrapper.vm as any).loadOrders()
    resolveNewer({
      data: { items: [{ id: 2 }], total: 1, page: 1, page_size: 20, pages: 1 },
    })
    await flushPromises()
    resolveOlder({
      data: { items: [{ id: 1 }], total: 1, page: 1, page_size: 20, pages: 1 },
    })
    await Promise.all([olderRequest, newerRequest])

    expect((wrapper.vm as any).orders).toEqual([{ id: 2 }])
    expect((wrapper.vm as any).ordersLoading).toBe(false)
  })
})
