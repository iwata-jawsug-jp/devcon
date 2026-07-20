<script setup lang="ts">
import { ref } from 'vue';
import { useGreetingQuery } from '../api';

const name = ref('JAWS-UG');
const { data, isError, isLoading } = useGreetingQuery(name);
</script>

<template>
  <div class="greeting-card mt-4 rounded border border-gray-200 p-4">
    <label class="block text-sm">
      名前:
      <input v-model="name" type="text" class="ml-2 rounded border border-gray-300 px-2 py-0.5" />
    </label>
    <p v-if="isLoading" class="mt-2 text-gray-600">読み込み中...</p>
    <p v-else-if="isError" class="mt-2 text-red-700">エラーが発生しました</p>
    <p v-else class="mt-2 font-sans text-lg" data-testid="greeting-message">
      {{ data?.message }}
    </p>
  </div>
</template>
