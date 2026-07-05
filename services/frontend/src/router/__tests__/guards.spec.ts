/**
 * Task 3.4 (RouterGuard) — `authGuard` unit tests, extended by task 4.2.
 *
 * Proves the generic guard mechanism in isolation using a throwaway
 * test-only router with synthetic routes; it never touches the real app's
 * `routes` array in `router/index.ts` (none of which currently declare
 * `meta.requiresAuth` -- see that file's doc comment).
 *
 * Contract under test (requirements.md 3.1; design.md Components and
 * Interfaces / Web / router "RouterGuard"): when `to.meta.requiresAuth` is
 * true and the auth store reports `!isAuthenticated`, redirect to `/login`
 * carrying `redirect=<to.fullPath>` -- the query-param contract task 2.3's
 * `stores/auth.ts` `login()` already reads to resume the original
 * destination after a successful login.
 *
 * Task 4.2 (requirements.md 3.1, 3.4) adds one more scenario at the bottom
 * of the `describe` block below: authenticate, reach the protected route,
 * log out, then prove the guard blocks the SAME route again -- i.e. the
 * guard re-reads live auth state on every navigation instead of caching an
 * earlier authenticated result. The first bullet of task 4.2 ("unauthenticated
 * -> redirected to /login") is already fully covered by the first test in
 * this file below (task 3.4); nothing new was added for it.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { createMemoryHistory, createRouter, type Router } from 'vue-router';
import { defineComponent } from 'vue';
import { mount } from '@vue/test-utils';
import { authGuard } from '../index';
import { useAuthStore } from '../../stores/auth';

/**
 * Builds a throwaway router with three test-only routes (public, a
 * synthetic protected route, and `/login`) and registers `authGuard` on it.
 * Also mounts a harness component so `useAuthStore()` (which itself calls
 * `useRoute()`/`useRouter()` once, at store-setup time -- see
 * `stores/auth.ts`'s doc comment) initializes inside a real app + router
 * injection context, exactly like `main.ts` does and the same pattern
 * `stores/__tests__/auth.spec.ts` uses.
 */
function setupTestRouter(): { router: Router; store: ReturnType<typeof useAuthStore> } {
  const pinia = createPinia();
  setActivePinia(pinia);

  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/public', name: 'public', component: { template: '<div />' } },
      {
        path: '/protected',
        name: 'protected',
        component: { template: '<div />' },
        meta: { requiresAuth: true },
      },
      { path: '/login', name: 'login', component: { template: '<div />' } },
    ],
  });
  router.beforeEach(authGuard);

  let store!: ReturnType<typeof useAuthStore>;
  const Harness = defineComponent({
    setup() {
      store = useAuthStore();
      return () => null;
    },
  });
  mount(Harness, { global: { plugins: [pinia, router] } });

  return { router, store };
}

describe('authGuard', () => {
  beforeEach(() => {
    // task 4.2 (requirements.md 3.4): the logout scenario below exercises
    // the real `authStore.logout()`, which as its final step assigns
    // `window.location.href` to Cognito's Hosted UI logout URL (see
    // `stores/auth.ts`). jsdom has no real navigation, so stub `location`
    // exactly like `stores/__tests__/auth.spec.ts` (task 2.3) already does,
    // to observe the assignment without jsdom logging a "not implemented"
    // navigation error.
    vi.stubGlobal('location', { href: '' });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('redirects an unauthenticated user away from a protected route to /login, preserving the original full path (including query) as the redirect query param', async () => {
    const { router } = setupTestRouter();

    await router.push('/protected?foo=bar');
    await router.isReady();

    expect(router.currentRoute.value.name).toBe('login');
    expect(router.currentRoute.value.query.redirect).toBe('/protected?foo=bar');
  });

  it('allows an authenticated user to reach the protected route without redirecting', async () => {
    const { router, store } = setupTestRouter();
    store.user = { sub: 'user-123', scopes: [] };

    await router.push('/protected');
    await router.isReady();

    expect(router.currentRoute.value.name).toBe('protected');
  });

  it('never redirects when navigating to a public route, regardless of auth state', async () => {
    const { router } = setupTestRouter();

    await router.push('/public');
    await router.isReady();

    expect(router.currentRoute.value.name).toBe('public');
  });

  it('does not loop or redirect when navigating directly to /login', async () => {
    const { router } = setupTestRouter();

    await router.push('/login');
    await router.isReady();

    expect(router.currentRoute.value.name).toBe('login');
  });

  /**
   * Task 4.2 (requirements.md 3.4; design.md Requirements Traceability row
   * "3.4 | ログアウトで状態破棄 | authStore.logout"): proves the guard
   * re-evaluates fresh auth state on every navigation rather than caching an
   * earlier "was authenticated" result. Calls the real `authStore.logout()`
   * (task 2.3, already unit-tested in isolation by `stores/__tests__/auth.spec.ts`)
   * so this test exercises the actual end-to-end wiring described by
   * "ログアウト後" -- not a hand-rolled stand-in for it -- while stubbing
   * `window.location` (see the `beforeEach` above) so `logout()`'s final
   * `window.location.href = ...` assignment is a no-op observation point
   * instead of a jsdom navigation attempt.
   *
   * Navigates to `/public` in between logout and the re-attempt rather than
   * pushing `/protected` -> `/protected` directly: vue-router's history API
   * treats a push to the exact current `fullPath` as a redundant navigation
   * and resolves it WITHOUT running `beforeEach` guards at all (confirmed
   * empirically -- the guard's call count does not increase), which would
   * make this test pass vacuously regardless of auth state. Routing through
   * `/public` first (mirroring a realistic post-logout state, since logout
   * navigates the browser away from the current page) forces `authGuard` to
   * actually re-run for the second `/protected` attempt.
   */
  it('blocks the protected route again after logout, even though it was reachable moments before', async () => {
    const { router, store } = setupTestRouter();
    store.user = { sub: 'user-123', scopes: [] };

    await router.push('/protected');
    await router.isReady();
    expect(router.currentRoute.value.name).toBe('protected');

    await store.logout();
    expect(store.isAuthenticated).toBe(false);

    await router.push('/public');
    await router.isReady();

    await router.push('/protected');
    await router.isReady();

    expect(router.currentRoute.value.name).toBe('login');
    expect(router.currentRoute.value.query.redirect).toBe('/protected');
  });
});
