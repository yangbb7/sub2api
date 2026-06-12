<template>
  <div class="min-h-screen bg-gray-50 dark:bg-dark-950">
    <!-- Background Decoration -->
    <div class="pointer-events-none fixed inset-0 bg-mesh-gradient"></div>

    <!-- Sidebar -->
    <AppSidebar />

    <!-- Main Content Area -->
    <div
      class="relative min-h-screen transition-all duration-300"
      :class="[sidebarCollapsed ? 'lg:ml-[72px]' : 'lg:ml-64']"
    >
      <!-- Header -->
      <AppHeader />

      <!-- Main Content -->
      <main class="p-4 md:p-6 lg:p-8">
        <slot />
      </main>
    </div>

    <SecurityStatementModal
      v-if="securityStatementDocument"
      :visible="showSecurityStatement"
      :document="securityStatementDocument"
      @acknowledge="acknowledgeSecurityStatement"
    />
  </div>
</template>

<script setup lang="ts">
import '@/styles/onboarding.css'
import { computed, onMounted, ref, watch } from 'vue'
import { useAppStore } from '@/stores'
import { useAuthStore } from '@/stores/auth'
import { useOnboardingTour } from '@/composables/useOnboardingTour'
import { useOnboardingStore } from '@/stores/onboarding'
import type { LoginAgreementDocument } from '@/types'
import AppSidebar from './AppSidebar.vue'
import AppHeader from './AppHeader.vue'
import SecurityStatementModal from './SecurityStatementModal.vue'

const appStore = useAppStore()
const authStore = useAuthStore()
const sidebarCollapsed = computed(() => appStore.sidebarCollapsed)
const isAdmin = computed(() => authStore.user?.role === 'admin')
const showSecurityStatement = ref(false)

const securityStatementDocument = computed<LoginAgreementDocument | null>(() => {
  const documents = appStore.cachedPublicSettings?.login_agreement_documents ?? []
  return documents.find((doc) => doc.id === 'security-privacy' && doc.content_md?.trim()) ?? null
})

const securityStatementRevision = computed(() => {
  const explicitRevision = appStore.cachedPublicSettings?.login_agreement_revision?.trim()
  if (explicitRevision) {
    return explicitRevision
  }
  const doc = securityStatementDocument.value
  return doc ? `${doc.id}:${doc.title}:${doc.content_md.length}` : ''
})

const securityStatementStorageKey = computed(() => {
  const user = authStore.user
  const revision = securityStatementRevision.value
  if (!user || !revision) {
    return ''
  }
  return `gateway_security_statement_ack:user:${user.id || user.email}:${revision}`
})

const { replayTour } = useOnboardingTour({
  storageKey: isAdmin.value ? 'admin_guide' : 'user_guide',
  autoStart: true
})

const onboardingStore = useOnboardingStore()

function shouldShowSecurityStatement(): boolean {
  const storageKey = securityStatementStorageKey.value
  if (!authStore.user || !securityStatementDocument.value || !storageKey) {
    return false
  }
  try {
    return localStorage.getItem(storageKey) !== '1'
  } catch {
    return true
  }
}

function syncSecurityStatementPrompt(): void {
  showSecurityStatement.value = shouldShowSecurityStatement()
}

function acknowledgeSecurityStatement(): void {
  const storageKey = securityStatementStorageKey.value
  if (storageKey) {
    try {
      localStorage.setItem(storageKey, '1')
    } catch {
      // If storage is blocked, keep the session usable after the explicit acknowledgement.
    }
  }
  showSecurityStatement.value = false
}

watch(
  [() => authStore.user?.id, securityStatementDocument, securityStatementRevision],
  syncSecurityStatementPrompt,
  { immediate: true }
)

onMounted(() => {
  onboardingStore.setReplayCallback(replayTour)
  syncSecurityStatementPrompt()
})

defineExpose({ replayTour })
</script>
