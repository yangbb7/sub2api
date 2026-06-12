<template>
  <BaseDialog
    :show="visible"
    :title="t('securityStatementModal.title')"
    width="wide"
    :close-on-escape="false"
    :close-on-click-outside="false"
    :show-close-button="false"
    :z-index="160"
    @close="emit('acknowledge')"
  >
    <div class="space-y-5">
      <div class="rounded-xl border border-primary-500/20 bg-primary-500/10 p-4">
        <div class="flex items-start gap-3">
          <span class="mt-0.5 flex h-10 w-10 flex-shrink-0 items-center justify-center rounded-lg bg-primary-600/10 text-primary-600 dark:text-primary-300">
            <Icon name="shield" size="md" />
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-sm font-semibold text-gray-950 dark:text-white">
              {{ t('securityStatementModal.noticeTitle') }}
            </p>
            <p class="mt-1 text-sm leading-6 text-gray-600 dark:text-dark-300">
              {{ t('securityStatementModal.noticeBody') }}
            </p>
          </div>
        </div>
      </div>

      <div
        class="max-h-[52vh] overflow-y-auto rounded-xl border border-gray-200 bg-white px-5 py-4 dark:border-dark-700 dark:bg-dark-900"
        data-testid="security-statement-content"
      >
        <article
          class="prose prose-sm max-w-none dark:prose-invert prose-headings:tracking-normal prose-a:text-primary-600 dark:prose-a:text-primary-300"
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
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-end">
        <button
          type="button"
          class="btn btn-primary w-full sm:w-auto"
          data-testid="security-statement-acknowledge"
          @click="emit('acknowledge')"
        >
          <Icon name="check" size="sm" class="mr-2" />
          {{ t('securityStatementModal.acknowledge') }}
        </button>
      </div>
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
  visible: boolean
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
