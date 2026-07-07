import { mount, flushPromises } from '@vue/test-utils'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { defineComponent } from 'vue'
import OpsDashboardHeader from '../OpsDashboardHeader.vue'

const mockGetGroups = vi.fn()
const mockGetRealtimeTrafficSummary = vi.fn()

vi.mock('@/api', () => ({
  adminAPI: {
    groups: {
      getAll: () => mockGetGroups(),
    },
  },
}))

vi.mock('@/api/admin/ops', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/api/admin/ops')>()
  return {
    ...actual,
    opsAPI: {
      getRealtimeTrafficSummary: (...args: any[]) => mockGetRealtimeTrafficSummary(...args),
    },
  }
})

vi.mock('@/stores', () => ({
  useAdminSettingsStore: () => ({
    opsRealtimeMonitoringEnabled: true,
    setOpsRealtimeMonitoringEnabledLocal: vi.fn(),
  }),
}))

vi.mock('vue-i18n', async (importOriginal) => {
  const actual = await importOriginal<typeof import('vue-i18n')>()
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string) => {
        const labels: Record<string, string> = {
          'admin.ops.disk': 'Disk',
          'admin.ops.memory': 'Memory',
          'admin.ops.noData': 'No data',
          'common.warning': 'Warning',
          'common.critical': 'Critical',
          'common.all': 'All',
          'common.total': 'Total',
          'admin.ops.current': 'Current',
          'admin.ops.queue': 'Queue',
          'admin.ops.jobs': 'Jobs',
          'admin.ops.conns': 'Conns',
          'admin.ops.active': 'Active',
          'admin.ops.idle': 'Idle',
          'admin.ops.idleStatus': 'Idle',
          'admin.ops.waiting': 'Waiting',
          'admin.ops.riskyStatus': 'Risk',
          'admin.ops.ok': 'OK',
        }
        return labels[key] ?? key
      },
    }),
  }
})

vi.mock('@/utils/format', () => ({
  formatNumber: (value: number) => Number(value).toLocaleString('en-US'),
}))

const SelectStub = defineComponent({
  name: 'SelectControlStub',
  props: {
    modelValue: { type: [String, Number, Boolean, null], default: '' },
    options: { type: Array, default: () => [] },
  },
  template: '<div class="select-stub" />',
})

const HelpTooltipStub = defineComponent({
  name: 'HelpTooltip',
  props: {
    content: { type: String, default: '' },
  },
  template: '<span class="help-tooltip-stub" />',
})

const BaseDialogStub = defineComponent({
  name: 'BaseDialog',
  props: {
    show: { type: Boolean, default: false },
    title: { type: String, default: '' },
  },
  template: '<div v-if="show" class="dialog-stub"><slot /></div>',
})

const IconStub = defineComponent({
  name: 'Icon',
  template: '<span class="icon-stub" />',
})

const overview = {
  start_time: '2026-06-13T10:00:00Z',
  end_time: '2026-06-13T11:00:00Z',
  platform: '',
  group_id: null,
  health_score: 96,
  system_metrics: {
    id: 1,
    created_at: '2026-06-13T10:59:00Z',
    window_minutes: 1,
    cpu_usage_percent: 12.5,
    memory_used_mb: 512,
    memory_total_mb: 1024,
    memory_usage_percent: 50,
    disk_used_mb: 2048,
    disk_total_mb: 4096,
    disk_usage_percent: 50,
    db_ok: true,
    redis_ok: true,
    redis_conn_total: 2,
    redis_conn_idle: 1,
    db_conn_active: 1,
    db_conn_idle: 3,
    db_conn_waiting: 0,
    goroutine_count: 42,
    concurrency_queue_depth: 0,
    account_switch_count: 0,
  },
  job_heartbeats: [],
  success_count: 10,
  error_count_total: 0,
  business_limited_count: 0,
  error_count_sla: 0,
  request_count_total: 10,
  request_count_sla: 10,
  token_consumed: 1000,
  sla: 1,
  error_rate: 0,
  upstream_error_rate: 0,
  upstream_error_count_excl_429_529: 0,
  upstream_429_count: 0,
  upstream_529_count: 0,
  qps: { current: 0.1, peak: 0.2, avg: 0.1 },
  tps: { current: 10, peak: 20, avg: 10 },
  duration: {},
  ttft: {},
}

describe('OpsDashboardHeader disk metrics', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockGetGroups.mockResolvedValue([])
    mockGetRealtimeTrafficSummary.mockResolvedValue({ enabled: true, summary: null })
  })

  it('renders disk usage with used and total capacity in the system health cards', async () => {
    const wrapper = mount(OpsDashboardHeader, {
      props: {
        overview: overview as any,
        platform: '',
        groupId: null,
        timeRange: '1h',
        queryMode: 'auto',
        loading: false,
        lastUpdated: new Date('2026-06-13T11:00:00Z'),
        thresholds: null,
      },
      global: {
        stubs: {
          Select: SelectStub,
          HelpTooltip: HelpTooltipStub,
          BaseDialog: BaseDialogStub,
          Icon: IconStub,
        },
      },
    })

    await flushPromises()

    expect(wrapper.text()).toContain('Disk')
    expect(wrapper.text()).toContain('50.0%')
    expect(wrapper.text()).toContain('2,048 / 4,096 MB')
  })

  it('does not show idle when the selected window still has traffic but current qps is zero', async () => {
    const wrapper = mount(OpsDashboardHeader, {
      props: {
        overview: {
          ...overview,
          health_score: 63,
          qps: { current: 0, peak: 0.2, avg: 0.1 },
          tps: { current: 648.8, peak: 1766.2, avg: 648.8 },
          request_count_total: 107,
          token_consumed: 2_336_000,
          duration: { p99_ms: 43105 },
          ttft: { p99_ms: 26996 },
        } as any,
        platform: '',
        groupId: null,
        timeRange: '1h',
        queryMode: 'auto',
        loading: false,
        lastUpdated: new Date('2026-06-13T11:00:00Z'),
        thresholds: null,
      },
      global: {
        stubs: {
          Select: SelectStub,
          HelpTooltip: HelpTooltipStub,
          BaseDialog: BaseDialogStub,
          Icon: IconStub,
        },
      },
    })

    await flushPromises()

    expect(wrapper.text()).toContain('63')
    expect(wrapper.text()).toContain('Risk')
    expect(wrapper.text()).not.toContain('admin.ops.healthCondition Idle')
  })
})
