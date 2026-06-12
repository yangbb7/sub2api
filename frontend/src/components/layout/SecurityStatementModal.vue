<template>
  <BaseDialog
    :show="show"
    :title="document.title || t('securityStatementModal.title')"
    width="wide"
    :close-on-escape="false"
    :close-on-click-outside="false"
    :show-close-button="false"
    :z-index="160"
  >
    <div class="space-y-4">
      <div class="rounded-lg border border-primary-500/20 bg-primary-500/10 p-4">
        <div class="flex items-start gap-3">
          <span class="mt-0.5 flex h-10 w-10 flex-shrink-0 items-center justify-center rounded-lg bg-primary-600/10 text-primary-600 dark:text-primary-300">
            <Icon name="shield" size="md" />
          </span>
          <p class="min-w-0 text-sm leading-6 text-gray-700 dark:text-dark-200">
            {{ t('securityStatementModal.summary') }}
          </p>
        </div>
      </div>

      <div
        class="max-h-[52vh] overflow-y-auto rounded-lg border border-gray-200 bg-white px-5 py-4 dark:border-dark-700 dark:bg-dark-900"
        data-testid="security-statement-content"
      >
        <article
          class="security-statement-content text-sm leading-7 text-gray-700 dark:text-dark-200"
          v-html="renderedHtml"
        ></article>
      </div>

      <RouterLink
        :to="documentRoute"
        target="_blank"
        rel="noopener noreferrer"
        class="inline-flex items-center gap-2 text-sm font-medium text-primary-600 transition hover:text-primary-700 dark:text-primary-300 dark:hover:text-primary-200"
      >
        <Icon name="externalLink" size="sm" />
        {{ t('securityStatementModal.openFullStatement') }}
      </RouterLink>
    </div>

    <template #footer>
      <button
        type="button"
        class="btn btn-primary w-full sm:w-auto"
        data-testid="security-statement-ack"
        @click="emit('acknowledge')"
      >
        <Icon name="check" size="sm" class="mr-2" />
        {{ t('securityStatementModal.acknowledge') }}
      </button>
    </template>
  </BaseDialog>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { marked } from 'marked'
import DOMPurify from 'dompurify'
import BaseDialog from '@/components/common/BaseDialog.vue'
import Icon from '@/components/icons/Icon.vue'
import type { LoginAgreementDocument } from '@/types'

const props = defineProps<{
  show: boolean
  document: LoginAgreementDocument
}>()

const emit = defineEmits<{
  acknowledge: []
}>()

const { t } = useI18n()

marked.setOptions({
  gfm: true,
  breaks: true,
})

const renderedHtml = computed(() => {
  const html = marked.parse(props.document.content_md || '') as string
  return DOMPurify.sanitize(html)
})

const documentRoute = computed(() => ({
  name: 'LegalDocument',
  params: {
    documentId: props.document.id || 'security-privacy',
  },
}))
</script>

<style scoped>
.security-statement-content :deep(h1),
.security-statement-content :deep(h2),
.security-statement-content :deep(h3) {
  margin: 0 0 0.75rem;
  color: inherit;
  font-weight: 700;
  letter-spacing: 0;
}

.security-statement-content :deep(h1) {
  font-size: 1.25rem;
}

.security-statement-content :deep(h2) {
  font-size: 1.125rem;
}

.security-statement-content :deep(h3) {
  font-size: 1rem;
}

.security-statement-content :deep(p),
.security-statement-content :deep(ul),
.security-statement-content :deep(ol) {
  margin: 0 0 0.875rem;
}

.security-statement-content :deep(ul),
.security-statement-content :deep(ol) {
  padding-left: 1.25rem;
}

.security-statement-content :deep(a) {
  color: rgb(13 148 136);
  font-weight: 600;
}
</style>
