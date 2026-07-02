<script setup lang="ts">
import { RouterLink, RouterView } from 'vue-router';
import { useHead } from '@unhead/vue';

// Site-wide title template; routes set their own `title` via useHead() and it
// gets wrapped in this. See docs/app-development.md for the per-route pattern.
// Also carries the PWA manifest link's companions (theme-color, apple-touch-icon)
// that vite-plugin-pwa doesn't inject on its own (#80).
useHead({
  titleTemplate: (title) => (title ? `${title} | devcon` : 'devcon'),
  meta: [{ name: 'theme-color', content: '#3d5fce' }],
  link: [{ rel: 'apple-touch-icon', href: '/apple-touch-icon.png' }],
});
</script>

<template>
  <header>
    <h1>web</h1>
    <nav>
      <RouterLink to="/"> Home </RouterLink>
    </nav>
  </header>
  <main>
    <RouterView />
  </main>
</template>
