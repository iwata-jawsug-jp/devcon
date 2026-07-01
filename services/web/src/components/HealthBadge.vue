<script setup lang="ts">
import { computed } from 'vue';
import { useHealthQuery } from '../api';

const { data, isError } = useHealthQuery();

const status = computed(() => {
  if (isError.value) return 'error';
  return data.value?.status ?? 'loading';
});

const statusClasses = computed(() => {
  switch (status.value) {
    case 'ok':
      return 'bg-brand-50 text-brand-700';
    case 'error':
      return 'bg-red-50 text-red-700';
    default:
      return 'bg-gray-100 text-gray-600';
  }
});
</script>

<template>
  <span
    class="health-badge inline-block rounded px-2 py-0.5 font-sans text-sm"
    :class="statusClasses"
    :data-status="status"
  >API: {{ status }}</span>
</template>
