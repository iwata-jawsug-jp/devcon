<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { apiClient } from '../api';

const status = ref<string>('loading');

onMounted(async () => {
  try {
    const health = await apiClient.getHealth();
    status.value = health.status;
  } catch {
    status.value = 'error';
  }
});
</script>

<template>
  <span
    class="health-badge"
    :data-status="status"
  >API: {{ status }}</span>
</template>

<style scoped>
.health-badge {
  display: inline-block;
  padding: 0.125rem 0.5rem;
  border-radius: 0.25rem;
  font-size: 0.875rem;
}
</style>
