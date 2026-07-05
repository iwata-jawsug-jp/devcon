/**
 * Task 3.2 — `LoginView` unit tests.
 *
 * Definition of Done (tasks.md 3.2 / requirements.md 3.1): mounting the view
 * kicks off the Hosted UI redirect by calling the real `useAuthStore()`'s
 * `login()` action exactly once. We stub `login()` itself (rather than
 * mocking `oidc-client-ts`) so the test never lets a real
 * `window.location` redirect happen in jsdom -- this mirrors the store's own
 * public action surface, which `stores/__tests__/auth.spec.ts` already
 * covers in full (redirect target, Cognito URL construction, etc.).
 */
import { afterEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { createMemoryHistory, createRouter, type Router } from 'vue-router';
import { defineComponent } from 'vue';
import { createHead } from '@unhead/vue/client';
import LoginView from '../LoginView.vue';
import { useAuthStore } from '../../stores/auth';

/**
 * Instantiates the real `useAuthStore()` inside a router-aware host
 * component first (mirrors `stores/__tests__/auth.spec.ts`'s `setupStore`
 * helper), so the store singleton already exists -- and can be stubbed --
 * before `LoginView` itself calls `useAuthStore()` in its own `setup()`.
 */
async function setupStoreAndRouter(initialPath = '/login'): Promise<{
  router: Router;
  store: ReturnType<typeof useAuthStore>;
}> {
  const pinia = createPinia();
  setActivePinia(pinia);

  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/', component: { template: '<div />' } },
      { path: '/login', name: 'login', component: LoginView },
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

describe('LoginView', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('calls authStore.login() exactly once on mount', async () => {
    const { router, store } = await setupStoreAndRouter();
    const login = vi.spyOn(store, 'login').mockResolvedValue(undefined);

    mount(LoginView, {
      global: { plugins: [router, createHead()] },
    });
    await flushPromises();

    expect(login).toHaveBeenCalledTimes(1);
  });

  it('renders an accessible redirecting message', async () => {
    const { router, store } = await setupStoreAndRouter();
    vi.spyOn(store, 'login').mockResolvedValue(undefined);

    const wrapper = mount(LoginView, {
      global: { plugins: [router, createHead()] },
    });
    await flushPromises();

    expect(wrapper.text()).toContain('ログインページへ移動しています');
  });
});
