/**
 * Task 3.5 — `AuthStatusBadge` unit tests.
 *
 * Definition of Done (tasks.md 3.5 / requirements.md 3.3): the badge renders
 * visibly different content for authenticated vs. unauthenticated state,
 * asserted via a distinct `data-status` attribute and distinct visible text
 * -- mirroring `HealthBadge.spec.ts`'s assertions on `.health-badge`'s
 * `data-status`.
 *
 * `useAuthStore()` itself calls `useRoute()`/`useRouter()` once at
 * store-setup time (see `stores/auth.ts`'s module doc comment), so -- like
 * `stores/__tests__/auth.spec.ts` and `views/__tests__/LoginView.spec.ts` --
 * we mount a throwaway host component inside a real Pinia + router context
 * first to create the store singleton, then set `store.user` directly to
 * drive `isAuthenticated` (a computed derived from `user !== null`) without
 * exercising the real OIDC login flow (out of scope for this presentational
 * component).
 */
import { describe, expect, it } from 'vitest';
import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { createMemoryHistory, createRouter, type Router } from 'vue-router';
import { defineComponent } from 'vue';
import AuthStatusBadge from '../AuthStatusBadge.vue';
import { useAuthStore } from '../../stores/auth';

async function setupStoreAndRouter(): Promise<{
  router: Router;
  store: ReturnType<typeof useAuthStore>;
}> {
  const pinia = createPinia();
  setActivePinia(pinia);

  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/', component: { template: '<div />' } }],
  });

  let store!: ReturnType<typeof useAuthStore>;
  const Harness = defineComponent({
    setup() {
      store = useAuthStore();
      return () => null;
    },
  });
  mount(Harness, { global: { plugins: [pinia, router] } });

  await router.push('/');
  await router.isReady();

  return { router, store };
}

describe('AuthStatusBadge', () => {
  it('shows the authenticated state when the auth store is authenticated', async () => {
    const { router, store } = await setupStoreAndRouter();
    store.user = { sub: 'user-123', scopes: [] };

    const wrapper = mount(AuthStatusBadge, {
      global: { plugins: [router] },
    });

    expect(wrapper.get('.auth-status-badge').attributes('data-status')).toBe('authenticated');
    expect(wrapper.text()).toContain('ログイン中');
  });

  it('shows the unauthenticated state when the auth store is not authenticated', async () => {
    const { router, store } = await setupStoreAndRouter();
    store.user = null;

    const wrapper = mount(AuthStatusBadge, {
      global: { plugins: [router] },
    });

    expect(wrapper.get('.auth-status-badge').attributes('data-status')).toBe('unauthenticated');
    expect(wrapper.text()).toContain('未ログイン');
  });
});
