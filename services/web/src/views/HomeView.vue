<script setup lang="ts">
import HealthBadge from '../components/HealthBadge.vue';
import { useCounterStore } from '../stores/counter';

const counter = useCounterStore();
</script>

<template>
  <section>
    <h2>Home</h2>
    <HealthBadge />
    <p>
      Count: {{ counter.count }} (doubled: {{ counter.doubled }})
      <button
        type="button"
        @click="counter.increment()"
      >
        Increment
      </button>
    </p>
  </section>
</template>
