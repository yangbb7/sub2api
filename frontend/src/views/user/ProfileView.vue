<template>
  <AppLayout>
    <div
      data-testid="profile-shell"
      class="mx-auto max-w-[950px] space-y-6"
    >
      <ProfileInfoCard
        :user="user"
        :linuxdo-enabled="linuxdoOAuthEnabled"
        :dingtalk-enabled="dingtalkOAuthEnabled"
        :oidc-enabled="oidcOAuthEnabled"
        :oidc-provider-name="oidcOAuthProviderName"
        :wechat-enabled="wechatOAuthEnabled"
        :wechat-open-enabled="wechatOAuthOpenEnabled"
        :wechat-mp-enabled="wechatOAuthMPEnabled"
      />

      <div v-if="affiliateEnabled" class="card p-6" data-testid="profile-affiliate-card">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h3 class="text-base font-semibold text-gray-900 dark:text-white">
              {{ t('profile.affiliate.title') }}
            </h3>
            <p class="mt-1 text-sm text-gray-500 dark:text-dark-400">
              {{ t('profile.affiliate.description') }}
            </p>
          </div>
          <RouterLink to="/affiliate" class="btn btn-secondary btn-sm">
            <Icon name="arrowRight" size="sm" />
            <span>{{ t('profile.affiliate.viewRecords') }}</span>
          </RouterLink>
        </div>

        <div v-if="affiliateLoading" class="mt-5 h-16 animate-pulse rounded-lg bg-gray-100 dark:bg-dark-800"></div>
        <div v-else-if="affiliateDetail" class="mt-5 space-y-4">
          <div class="grid gap-3 sm:grid-cols-3">
            <div class="rounded-lg border border-gray-200 p-3 dark:border-dark-700">
              <p class="text-xs text-gray-500 dark:text-dark-400">{{ t('profile.affiliate.invitedUsers') }}</p>
              <p class="mt-1 text-xl font-semibold text-gray-900 dark:text-white">
                {{ affiliateDetail.aff_count.toLocaleString() }}
              </p>
            </div>
            <div class="rounded-lg border border-gray-200 p-3 dark:border-dark-700">
              <p class="text-xs text-gray-500 dark:text-dark-400">{{ t('profile.affiliate.availableQuota') }}</p>
              <p class="mt-1 text-xl font-semibold text-emerald-600 dark:text-emerald-400">
                {{ formatCurrency(affiliateDetail.aff_quota) }}
              </p>
            </div>
            <div class="rounded-lg border border-gray-200 p-3 dark:border-dark-700">
              <p class="text-xs text-gray-500 dark:text-dark-400">{{ t('profile.affiliate.rebateRate') }}</p>
              <p class="mt-1 text-xl font-semibold text-primary-600 dark:text-primary-400">
                {{ formattedAffiliateRate }}%
              </p>
            </div>
          </div>

          <div class="flex flex-col gap-3 rounded-lg border border-gray-200 bg-gray-50 p-3 dark:border-dark-700 dark:bg-dark-900 sm:flex-row sm:items-center">
            <code class="min-w-0 flex-1 truncate text-sm text-gray-700 dark:text-gray-300">{{ affiliateInviteLink }}</code>
            <button class="btn btn-secondary btn-sm shrink-0" @click="copyAffiliateInviteLink">
              <Icon name="copy" size="sm" />
              <span>{{ t('profile.affiliate.copyLink') }}</span>
            </button>
          </div>
        </div>
      </div>

      <div
        v-if="contactInfo"
        class="card border-primary-200 bg-primary-50 p-6 dark:bg-primary-900/20"
      >
        <div class="flex items-center gap-4">
          <div class="rounded-xl bg-primary-100 p-3 text-primary-600">
            <Icon name="chat" size="lg" />
          </div>
          <div>
            <h3 class="font-semibold text-primary-800 dark:text-primary-200">
              {{ t('common.contactSupport') }}
            </h3>
            <p class="text-sm font-medium">{{ contactInfo }}</p>
          </div>
        </div>
      </div>

      <ProfilePasswordForm />

      <ProfileBalanceNotifyCard
        v-if="user && balanceLowNotifyEnabled"
        :enabled="user.balance_notify_enabled ?? true"
        :threshold="user.balance_notify_threshold"
        :extra-emails="user.balance_notify_extra_emails ?? []"
        :system-default-threshold="systemDefaultThreshold"
        :user-email="user.email"
      />

      <ProfileTotpCard />
      <ProfilePasskeyCard :enabled="passkeyEnabled" />
    </div>
  </AppLayout>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { RouterLink } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { Icon } from '@/components/icons'
import AppLayout from '@/components/layout/AppLayout.vue'
import ProfileBalanceNotifyCard from '@/components/user/profile/ProfileBalanceNotifyCard.vue'
import ProfileInfoCard from '@/components/user/profile/ProfileInfoCard.vue'
import ProfilePasswordForm from '@/components/user/profile/ProfilePasswordForm.vue'
import ProfileTotpCard from '@/components/user/profile/ProfileTotpCard.vue'
import ProfilePasskeyCard from '@/components/user/profile/ProfilePasskeyCard.vue'
import { isWeChatWebOAuthEnabled } from '@/api/auth'
import userAPI from '@/api/user'
import { useClipboard } from '@/composables/useClipboard'
import { useAppStore } from '@/stores/app'
import { useAuthStore } from '@/stores/auth'
import type { UserAffiliateDetail } from '@/types'
import { formatCurrency } from '@/utils/format'

const { t } = useI18n()
const appStore = useAppStore()
const authStore = useAuthStore()
const { copyToClipboard } = useClipboard()
const user = computed(() => authStore.user)

const contactInfo = ref('')
const balanceLowNotifyEnabled = ref(false)
const systemDefaultThreshold = ref(0)
const affiliateEnabled = ref(false)
const affiliateLoading = ref(false)
const affiliateDetail = ref<UserAffiliateDetail | null>(null)
const linuxdoOAuthEnabled = ref(false)
const dingtalkOAuthEnabled = ref(false)
const wechatOAuthEnabled = ref(false)
const wechatOAuthOpenEnabled = ref<boolean | undefined>(undefined)
const wechatOAuthMPEnabled = ref<boolean | undefined>(undefined)
const oidcOAuthEnabled = ref(false)
const oidcOAuthProviderName = ref('OIDC')
const passkeyEnabled = ref(false)

const affiliateInviteLink = computed(() => {
  if (!affiliateDetail.value?.aff_code) return ''
  const path = `/register?aff=${encodeURIComponent(affiliateDetail.value.aff_code)}`
  if (typeof window === 'undefined') return path
  return `${window.location.origin}${path}`
})

const formattedAffiliateRate = computed(() => {
  const rate = affiliateDetail.value?.effective_rebate_rate_percent ?? 0
  const rounded = Math.round(rate * 100) / 100
  return Number.isInteger(rounded) ? String(rounded) : String(rounded)
})

async function loadAffiliateDetail(): Promise<void> {
  affiliateLoading.value = true
  try {
    affiliateDetail.value = await userAPI.getAffiliateDetail()
  } catch (error) {
    console.error('Failed to load affiliate detail:', error)
    affiliateDetail.value = null
  } finally {
    affiliateLoading.value = false
  }
}

async function copyAffiliateInviteLink(): Promise<void> {
  if (!affiliateInviteLink.value) return
  await copyToClipboard(affiliateInviteLink.value, t('profile.affiliate.linkCopied'))
}

onMounted(async () => {
  const profileRefresh = authStore.refreshUser().catch((error) => {
    console.error('Failed to refresh profile:', error)
  })

  const settingsLoad = appStore.fetchPublicSettings()
    .then((settings) => {
      if (!settings) {
        return
      }
      contactInfo.value = settings.contact_info || ''
      balanceLowNotifyEnabled.value = settings.balance_low_notify_enabled ?? false
      systemDefaultThreshold.value = settings.balance_low_notify_threshold ?? 0
      affiliateEnabled.value = settings.affiliate_enabled !== false
      if (affiliateEnabled.value) {
        void loadAffiliateDetail()
      }
      linuxdoOAuthEnabled.value = settings.linuxdo_oauth_enabled ?? false
      dingtalkOAuthEnabled.value = settings.dingtalk_oauth_enabled ?? false
      wechatOAuthEnabled.value = isWeChatWebOAuthEnabled(settings)
      wechatOAuthOpenEnabled.value = typeof settings.wechat_oauth_open_enabled === 'boolean'
        ? settings.wechat_oauth_open_enabled
        : undefined
      wechatOAuthMPEnabled.value = typeof settings.wechat_oauth_mp_enabled === 'boolean'
        ? settings.wechat_oauth_mp_enabled
        : undefined
      oidcOAuthEnabled.value = settings.oidc_oauth_enabled ?? false
      oidcOAuthProviderName.value = settings.oidc_oauth_provider_name || 'OIDC'
      passkeyEnabled.value = settings.passkey_enabled === true
    })
    .catch((error) => {
      console.error('Failed to load settings:', error)
    })

  await Promise.all([profileRefresh, settingsLoad])
})
</script>
