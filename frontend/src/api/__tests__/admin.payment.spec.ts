import { beforeEach, describe, expect, it, vi } from 'vitest'

const { get } = vi.hoisted(() => ({
  get: vi.fn(),
}))

vi.mock('@/api/client', () => ({
  apiClient: { get },
}))

import { adminPaymentAPI } from '@/api/admin/payment'

describe('admin payment API', () => {
  beforeEach(() => {
    get.mockReset()
    get.mockResolvedValue({ data: {} })
  })

  it('queries dashboard statistics with an explicit date range', async () => {
    const params = { start_date: '2026-06-01', end_date: '2026-06-30' }

    await adminPaymentAPI.getDashboard(params)

    expect(get).toHaveBeenCalledWith('/admin/payment/dashboard', { params })
  })

  it('keeps date and order filters on paginated list requests', async () => {
    const params = {
      page: 3,
      page_size: 50,
      keyword: 'invoice-42',
      status: 'COMPLETED',
      payment_type: 'stripe',
      order_type: 'subscription',
      start_date: '2026-05-01',
      end_date: '2026-05-31',
    }

    await adminPaymentAPI.getOrders(params)

    expect(get).toHaveBeenCalledWith('/admin/payment/orders', { params })
  })

  it('downloads a CSV blob using the same filters without pagination', async () => {
    const params = {
      keyword: 'customer@example.com',
      status: 'PAID',
      start_date: '2026-07-01',
      end_date: '2026-07-16',
    }

    await adminPaymentAPI.exportOrders(params)

    expect(get).toHaveBeenCalledWith('/admin/payment/orders/export', {
      params,
      responseType: 'blob',
    })
  })
})
