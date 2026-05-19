<template>
  <div class="min-h-screen bg-gray-50 text-gray-900 dark:bg-dark-950 dark:text-gray-100">
    <div class="mx-auto grid min-h-screen w-full max-w-6xl items-center gap-10 px-4 py-8 sm:px-6 lg:grid-cols-[1fr_448px] lg:py-12">
      <section class="hidden lg:block">
        <div class="flex items-center gap-3">
          <span class="flex h-12 w-12 items-center justify-center overflow-hidden rounded-lg bg-white ring-1 ring-gray-200 dark:bg-dark-900 dark:ring-dark-700">
            <img
              :src="siteLogo || DEFAULT_LOGO_URL"
              :alt="`${siteName} logo`"
              width="48"
              height="48"
              class="h-full w-full object-contain"
            />
          </span>
          <div class="min-w-0">
            <h1 class="truncate text-2xl font-semibold tracking-normal text-gray-950 dark:text-white">
              {{ siteName }}
            </h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-dark-400">
              {{ siteSubtitle }}
            </p>
          </div>
        </div>
      </section>

      <div class="w-full max-w-md justify-self-center lg:justify-self-end">
        <div class="mb-6 text-center lg:hidden">
          <span class="mb-3 inline-flex h-14 w-14 items-center justify-center overflow-hidden rounded-lg bg-white ring-1 ring-gray-200 dark:bg-dark-900 dark:ring-dark-700">
            <img
              :src="siteLogo || DEFAULT_LOGO_URL"
              :alt="`${siteName} logo`"
              width="56"
              height="56"
              class="h-full w-full object-contain"
            />
          </span>
          <h1 class="text-2xl font-semibold tracking-normal text-gray-950 dark:text-white">
            {{ siteName }}
          </h1>
          <p class="mt-1 text-sm text-gray-500 dark:text-dark-400">
            {{ siteSubtitle }}
          </p>
        </div>

        <div class="rounded-lg border border-gray-200 bg-white p-6 shadow-sm dark:border-dark-800 dark:bg-dark-900 sm:p-8">
          <slot />
        </div>

        <div class="mt-6 text-center text-sm">
          <slot name="footer" />
        </div>

        <div class="mt-8 text-center text-xs text-gray-400 dark:text-dark-500">
          &copy; {{ currentYear }} {{ siteName }}. All rights reserved.
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useAppStore } from '@/stores'
import { sanitizeUrl } from '@/utils/url'
import { DEFAULT_LOGO_URL, DEFAULT_SITE_NAME, DEFAULT_SITE_SUBTITLE } from '@/constants/branding'

const appStore = useAppStore()

const siteName = computed(() => appStore.siteName || DEFAULT_SITE_NAME)
const siteLogo = computed(() => sanitizeUrl(appStore.siteLogo || '', { allowRelative: true, allowDataUrl: true }))
const siteSubtitle = computed(() => appStore.cachedPublicSettings?.site_subtitle || DEFAULT_SITE_SUBTITLE)

const currentYear = computed(() => new Date().getFullYear())

onMounted(() => {
  appStore.fetchPublicSettings()
})
</script>
