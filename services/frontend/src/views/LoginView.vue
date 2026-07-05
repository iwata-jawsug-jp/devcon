<script setup lang="ts">
/**
 * Task 3.2 — login entry point (Requirement 3.1).
 *
 * Purely a presentational redirect trigger: on mount it delegates to
 * `authStore.login()`, which reads `route.query.redirect` itself and starts
 * the Cognito Hosted UI redirect (`.kiro/specs/authn-authz/design.md` >
 * Components and Interfaces > Web / router, components: "ロジックは
 * `AuthStore` に委譲する"). This view holds no auth logic of its own.
 *
 * The rendered message is normally visible for only an instant, since
 * `login()` triggers a real full-page navigation away from the SPA -- but it
 * still needs to render something sensible (and testable) while that
 * navigation is in flight.
 */
import { onMounted } from 'vue';
import { useHead } from '@unhead/vue';
import { useAuthStore } from '../stores/auth';

const authStore = useAuthStore();

useHead({ title: 'ログイン' });

onMounted(() => {
  void authStore.login();
});
</script>

<template>
  <section>
    <p>ログインページへ移動しています…</p>
  </section>
</template>
