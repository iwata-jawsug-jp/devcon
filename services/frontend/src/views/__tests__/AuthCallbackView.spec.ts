/**
 * Task 3.2 — `AuthCallbackView` unit tests.
 *
 * Definition of Done (tasks.md 3.2 / requirements.md 3.2, 3.5): mounting the
 * view calls the real `useAuthStore()`'s `handleCallback()` exactly once. We
 * stub `handleCallback()` itself (rather than mocking `oidc-client-ts`), and
 * drive the store's real `error` ref directly to simulate the two outcomes
 * `handleCallback()` can leave behind (per task 2.3's contract):
 * - success: `error` stays `null` and the store itself already navigated
 *   away via `router.replace(...)` -- this view must not render an error.
 * - failure: `error` is set to a message and no navigation happens -- this
 *   view must render it in an accessible (`role="alert"`) element.
 *
 * `stores/__tests__/auth.spec.ts` already covers `handleCallback()`'s own
 * internal behavior (state transitions, navigation); this file only proves
 * the view wires up to that contract correctly.
 */
import { afterEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { createMemoryHistory, createRouter, type Router } from 'vue-router';
import { defineComponent } from 'vue';
import { createHead } from '@unhead/vue/client';
import AuthCallbackView from '../AuthCallbackView.vue';
import { useAuthStore } from '../../stores/auth';

/**
 * Instantiates the real `useAuthStore()` inside a router-aware host
 * component first (mirrors `stores/__tests__/auth.spec.ts`'s `setupStore`
 * helper), so the store singleton already exists -- and can be stubbed --
 * before `AuthCallbackView` itself calls `useAuthStore()` in its own
 * `setup()`.
 */
async function setupStoreAndRouter(initialPath = '/callback'): Promise<{
  router: Router;
  store: ReturnType<typeof useAuthStore>;
}> {
  const pinia = createPinia();
  setActivePinia(pinia);

  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/', component: { template: '<div />' } },
      { path: '/callback', name: 'callback', component: AuthCallbackView },
    ],
  });

  let store!: ReturnType<typeof useAuthStore>;
  const Harness = defineComponent({
    setup() {
      store = useAuthStore();
      return () => null;
    },
  });
  mount(Harness, { global: { plugins: [pinia, router] } });

  await router.push(initialPath);
  await router.isReady();

  return { router, store };
}

describe('AuthCallbackView', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('calls authStore.handleCallback() exactly once on mount', async () => {
    const { router, store } = await setupStoreAndRouter();
    const handleCallback = vi.spyOn(store, 'handleCallback').mockResolvedValue(undefined);

    mount(AuthCallbackView, {
      global: { plugins: [router, createHead()] },
    });
    await flushPromises();

    expect(handleCallback).toHaveBeenCalledTimes(1);
  });

  it('success: renders no error message once handleCallback() resolves without an error', async () => {
    const { router, store } = await setupStoreAndRouter();
    vi.spyOn(store, 'handleCallback').mockResolvedValue(undefined);

    const wrapper = mount(AuthCallbackView, {
      global: { plugins: [router, createHead()] },
    });
    await flushPromises();

    expect(wrapper.find('[role="alert"]').exists()).toBe(false);
  });

  it('failure: renders an accessible error message once the store error is set', async () => {
    const { router, store } = await setupStoreAndRouter();
    vi.spyOn(store, 'handleCallback').mockImplementation(async () => {
      store.error = 'ログインに失敗しました';
    });

    const wrapper = mount(AuthCallbackView, {
      global: { plugins: [router, createHead()] },
    });
    await flushPromises();

    const alert = wrapper.find('[role="alert"]');
    expect(alert.exists()).toBe(true);
    expect(alert.text()).toContain('ログインに失敗しました');
  });
});
