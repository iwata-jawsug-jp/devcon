import { computed, ref } from 'vue';
import { defineStore } from 'pinia';

export const useCounterStore = defineStore('counter', () => {
  const count = ref(0);
  const doubled = computed(() => count.value * 2);

  function increment(): void {
    count.value++;
  }

  return { count, doubled, increment };
});
