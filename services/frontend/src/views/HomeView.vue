<script setup lang="ts">
import HealthBadge from '../components/HealthBadge.vue';
import { useCounterStore } from '../stores/counter';
import { useHead } from '@unhead/vue';

const counter = useCounterStore();

const title = 'Home';
const description =
  'devcon — Dev Container 上で構築する Vite + Vue 3 SPA / FastAPI モノレポのテンプレート。';
const siteUrl = import.meta.env.VITE_SITE_URL || 'http://localhost:5173';

// Per-route SEO/OGP metadata. This route is build-time prerendered (vite-ssg),
// so this HTML is what crawlers and link-preview bots actually see — not a
// bot-only variant (no cloaking). Copy this pattern for future public routes.
useHead({
  title,
  meta: [
    { name: 'description', content: description },
    { property: 'og:type', content: 'website' },
    { property: 'og:title', content: title },
    { property: 'og:description', content: description },
    { property: 'og:url', content: siteUrl },
  ],
  script: [
    {
      type: 'application/ld+json',
      innerHTML: {
        '@context': 'https://schema.org',
        '@type': 'WebSite',
        name: 'devcon',
        url: siteUrl,
      },
    },
  ],
});
</script>

<template>
  <section>
    <h2>Home</h2>
    <HealthBadge />
    <p>
      Count: {{ counter.count }} (doubled: {{ counter.doubled }})
      <button type="button" @click="counter.increment()">Increment</button>
    </p>
  </section>
</template>
