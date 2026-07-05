<script setup lang="ts">
import { computed } from 'vue';
import { useAuthStore } from '../stores/auth';

const authStore = useAuthStore();

const status = computed(() => (authStore.isAuthenticated ? 'authenticated' : 'unauthenticated'));

const statusClasses = computed(() => {
  switch (status.value) {
    case 'authenticated':
      return 'bg-brand-50 text-brand-700';
    default:
      return 'bg-gray-100 text-gray-600';
  }
});

const statusLabel = computed(() =>
  status.value === 'authenticated' ? 'ログイン中' : '未ログイン',
);
</script>

<template>
  <span
    class="auth-status-badge inline-block rounded px-2 py-0.5 font-sans text-sm"
    :class="statusClasses"
    :data-status="status"
    >{{ statusLabel }}</span
  >
</template>
