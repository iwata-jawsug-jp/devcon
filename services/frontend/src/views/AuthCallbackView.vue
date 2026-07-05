<script setup lang="ts">
/**
 * Task 3.2 — OIDC redirect callback receiver (Requirements 3.2, 3.5).
 *
 * Purely a presentational callback receiver: on mount it delegates to
 * `authStore.handleCallback()`, which completes the authorization-code
 * exchange (`.kiro/specs/authn-authz/design.md` > Components and Interfaces
 * > Web / router, components: "ロジックは `AuthStore` に委譲する").
 *
 * - Success (Requirement 3.2): `handleCallback()` itself navigates via
 *   `router.replace(...)` to the original target and leaves `authStore.error`
 *   `null` -- this view renders nothing but a neutral in-progress message
 *   and never needs to navigate itself.
 * - Failure (Requirement 3.5, design.md Error Handling > "ログイン失敗"):
 *   `handleCallback()` sets `authStore.error` and does not navigate -- this
 *   view surfaces that message in an accessible `role="alert"` element.
 */
import { onMounted } from 'vue';
import { useHead } from '@unhead/vue';
import { useAuthStore } from '../stores/auth';

const authStore = useAuthStore();

useHead({ title: 'ログイン処理中' });

onMounted(() => {
  void authStore.handleCallback();
});
</script>

<template>
  <section>
    <p v-if="!authStore.error">ログイン処理を確認しています…</p>
    <p v-else role="alert">{{ authStore.error }}</p>
  </section>
</template>
