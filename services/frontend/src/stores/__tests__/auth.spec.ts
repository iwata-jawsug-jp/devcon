/**
 * Task 2.3 — `useAuthStore` unit tests.
 *
 * Definition of Done (tasks.md 2.3): login success / login failure / logout /
 * refresh success / refresh failure / refresh concurrency each leave the
 * in-memory auth state exactly as expected.
 *
 * `oidc-client-ts`'s `UserManager` is mocked entirely: this test proves the
 * store's own orchestration logic (state transitions, the "return to
 * original page" contract, the Cognito logout URL, refresh-promise sharing),
 * not `oidc-client-ts` itself (that library is trusted third-party code).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { createMemoryHistory, createRouter, type Router } from 'vue-router';
import { defineComponent } from 'vue';
import { mount } from '@vue/test-utils';
import type { User } from 'oidc-client-ts';
import { useAuthStore } from '../auth';

const signinRedirect = vi.fn();
const signinRedirectCallback = vi.fn();
const signinSilent = vi.fn();

const fakeSettings = {
  client_id: 'test-client-id',
  post_logout_redirect_uri: 'https://app.example.com/login',
};

vi.mock('oidc-client-ts', async (importOriginal) => {
  const actual = await importOriginal<typeof import('oidc-client-ts')>();
  return {
    ...actual,
    // `mockImplementation` must be a real function (not an arrow function)
    // so `new UserManager(...)` works: a constructor function that
    // explicitly returns an object makes `new` yield that object instead of
    // `this`.
    UserManager: vi.fn().mockImplementation(function FakeUserManager() {
      return {
        signinRedirect,
        signinRedirectCallback,
        signinSilent,
        settings: fakeSettings,
      };
    }),
  };
});

/** Minimal fake of oidc-client-ts's `User` (only the fields the store reads). */
function fakeOidcUser(overrides: Partial<User> = {}): User {
  return {
    access_token: 'access-token-value',
    token_type: 'Bearer',
    profile: { sub: 'user-123', iss: 'issuer', aud: 'aud', exp: 0, iat: 0 },
    scope: 'openid api/items.read api/items.write',
    session_state: null,
    state: undefined,
    ...overrides,
  } as User;
}

/**
 * Mounts a throwaway host component so `useAuthStore()` (which itself calls
 * `useRoute()`/`useRouter()` once, at store-setup time) is created inside a
 * real component + router injection context, exactly like a real app.
 */
async function setupStore(initialPath = '/'): Promise<{
  store: ReturnType<typeof useAuthStore>;
  router: Router;
}> {
  const pinia = createPinia();
  setActivePinia(pinia);

  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/', component: { template: '<div />' } },
      { path: '/login', component: { template: '<div />' } },
      { path: '/callback', component: { template: '<div />' } },
      { path: '/dashboard', component: { template: '<div />' } },
      { path: '/protected', component: { template: '<div />' } },
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
  return { store, router };
}

describe('useAuthStore', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.stubGlobal('location', { href: '' });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('starts unauthenticated with no access token', async () => {
    const { store } = await setupStore();

    expect(store.isAuthenticated).toBe(false);
    expect(store.user).toBeNull();
    expect(store.getAccessToken()).toBeNull();
  });

  describe('login()', () => {
    it('redirects to the Cognito Hosted UI, carrying the redirect query param as signin state', async () => {
      signinRedirect.mockResolvedValue(undefined);
      const { store } = await setupStore('/login?redirect=%2Fprotected');

      await store.login();

      expect(signinRedirect).toHaveBeenCalledWith({ state: '/protected' });
    });

    it('falls back to no state when there is no redirect query param', async () => {
      signinRedirect.mockResolvedValue(undefined);
      const { store } = await setupStore('/login');

      await store.login();

      expect(signinRedirect).toHaveBeenCalledWith({ state: undefined });
    });
  });

  describe('handleCallback()', () => {
    it('login success: applies the authenticated user and navigates to the state-carried redirect target', async () => {
      signinRedirectCallback.mockResolvedValue(fakeOidcUser({ state: '/dashboard' }));
      const { store, router } = await setupStore('/callback');

      await store.handleCallback();

      expect(store.isAuthenticated).toBe(true);
      expect(store.user).toEqual({
        sub: 'user-123',
        scopes: ['openid', 'api/items.read', 'api/items.write'],
      });
      expect(store.getAccessToken()).toBe('access-token-value');
      expect(store.error).toBeNull();
      expect(router.currentRoute.value.path).toBe('/dashboard');
    });

    it('falls back to "/" when no redirect state was carried', async () => {
      signinRedirectCallback.mockResolvedValue(fakeOidcUser({ state: undefined }));
      const { store, router } = await setupStore('/callback');

      await store.handleCallback();

      expect(router.currentRoute.value.path).toBe('/');
    });

    it('login failure: sets error state, stays unauthenticated, and does not navigate', async () => {
      signinRedirectCallback.mockRejectedValue(new Error('invalid_grant'));
      const { store, router } = await setupStore('/callback');

      await store.handleCallback();

      expect(store.isAuthenticated).toBe(false);
      expect(store.user).toBeNull();
      expect(store.getAccessToken()).toBeNull();
      expect(store.error).toBeTruthy();
      expect(router.currentRoute.value.path).toBe('/callback');
    });
  });

  describe('logout()', () => {
    it('clears in-memory state and navigates to the constructed Cognito logout URL', async () => {
      signinRedirectCallback.mockResolvedValue(fakeOidcUser());
      const { store } = await setupStore('/callback');
      await store.handleCallback();
      expect(store.isAuthenticated).toBe(true);

      await store.logout();

      expect(store.isAuthenticated).toBe(false);
      expect(store.user).toBeNull();
      expect(store.getAccessToken()).toBeNull();

      const logoutUrl = window.location.href;
      expect(logoutUrl).toContain('/logout?');
      expect(logoutUrl).toContain(`client_id=${fakeSettings.client_id}`);
      expect(logoutUrl).toContain(
        `logout_uri=${encodeURIComponent(fakeSettings.post_logout_redirect_uri)}`,
      );
    });
  });

  describe('refresh()', () => {
    it('refresh success: updates state from the silently-renewed user and returns true', async () => {
      signinSilent.mockResolvedValue(fakeOidcUser({ access_token: 'renewed-token' }));
      const { store } = await setupStore();

      const result = await store.refresh();

      expect(result).toBe(true);
      expect(store.isAuthenticated).toBe(true);
      expect(store.getAccessToken()).toBe('renewed-token');
    });

    it('refresh failure: clears state and returns false', async () => {
      signinRedirectCallback.mockResolvedValue(fakeOidcUser());
      const { store } = await setupStore('/callback');
      await store.handleCallback();
      expect(store.isAuthenticated).toBe(true);

      signinSilent.mockRejectedValue(new Error('login_required'));

      const result = await store.refresh();

      expect(result).toBe(false);
      expect(store.isAuthenticated).toBe(false);
      expect(store.user).toBeNull();
      expect(store.getAccessToken()).toBeNull();
    });

    it('refresh concurrency: concurrent calls share a single in-flight signinSilent()', async () => {
      let resolveSignin!: (user: User) => void;
      signinSilent.mockReturnValue(
        new Promise<User>((resolve) => {
          resolveSignin = resolve;
        }),
      );
      const { store } = await setupStore();

      const first = store.refresh();
      const second = store.refresh();

      expect(signinSilent).toHaveBeenCalledTimes(1);

      resolveSignin(fakeOidcUser());
      const [firstResult, secondResult] = await Promise.all([first, second]);

      expect(firstResult).toBe(true);
      expect(secondResult).toBe(true);
      expect(signinSilent).toHaveBeenCalledTimes(1);
    });
  });
});
