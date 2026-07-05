/**
 * Task 3.3 — `ApiClient`'s private `request()` auth-attach + 401
 * refresh-and-retry behavior.
 *
 * Definition of Done (tasks.md 3.3):
 * - Attaches `Authorization: Bearer <token>` when `authStore.getAccessToken()`
 *   returns a token and `skipAuth` isn't set.
 * - Never attaches the header when `skipAuth: true`, even if a token exists.
 * - A 401 triggers exactly one `authStore.refresh()`; on `true`, the request
 *   is retried exactly once with the refreshed token, and the retried
 *   response's data reaches the caller.
 * - On `refresh()` resolving `false`, `authStore.logout()` is called and the
 *   original 401 error propagates (rejects), not swallowed.
 * - A 401 on the retried request does not loop again (`fetch` at most twice,
 *   `refresh()` at most once).
 * - `skipAuth: true` requests never enter the refresh/retry dance at all.
 *
 * `request()` is private, so tests reach it via a same-package `as any` cast
 * on an `ApiClient` instance -- there is no public authenticated endpoint
 * method yet (task 3.3 only changes the shared `request()`; adding a new
 * endpoint method is out of this task's boundary). `getHealth()` is exercised
 * separately to confirm it stays on the `skipAuth` path.
 *
 * Auth store setup mirrors `stores/__tests__/auth.spec.ts`: `useAuthStore()`
 * calls `useRoute()`/`useRouter()` at store-setup time, so the store must be
 * created for the first time inside a mounted component with Pinia + a
 * router installed. After that, `ApiClient.request()`'s own `useAuthStore()`
 * calls simply return the already-created store instance (Pinia caches it),
 * which is exactly the SSR-safe pattern design.md calls for.
 */
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';
import { createMemoryHistory, createRouter } from 'vue-router';
import { defineComponent } from 'vue';
import { mount } from '@vue/test-utils';
import { ApiClient } from '../client';
import { useAuthStore } from '../../stores/auth';

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : status === 401 ? 'Unauthorized' : 'Error',
    json: async () => body,
  } as Response;
}

/**
 * Creates a fresh Pinia + router, mounts a throwaway host component so the
 * auth store's `useRoute()`/`useRouter()` setup-time calls succeed, and
 * returns the resulting store plus a private-method-callable `ApiClient`.
 */
async function setupClient(): Promise<{
  client: {
    request: <T>(path: string, init?: Record<string, unknown>) => Promise<T>;
  };
  authStore: ReturnType<typeof useAuthStore>;
}> {
  const pinia = createPinia();
  setActivePinia(pinia);

  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/', component: { template: '<div />' } }],
  });

  let authStore!: ReturnType<typeof useAuthStore>;
  const Harness = defineComponent({
    setup() {
      authStore = useAuthStore();
      return () => null;
    },
  });
  mount(Harness, { global: { plugins: [pinia, router] } });
  await router.isReady();

  const client = new ApiClient() as unknown as {
    request: <T>(path: string, init?: Record<string, unknown>) => Promise<T>;
  };
  return { client, authStore };
}

describe('ApiClient#request (private, via as-any cast)', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('attaches Authorization: Bearer <token> when a token exists and skipAuth is not set', async () => {
    const { client, authStore } = await setupClient();
    vi.spyOn(authStore, 'getAccessToken').mockReturnValue('token-abc');
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ ok: true }));
    vi.stubGlobal('fetch', fetchMock);

    const result = await client.request('/items');

    expect(result).toEqual({ ok: true });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0];
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer token-abc');
  });

  it('never attaches the Authorization header when skipAuth is true, even if a token exists', async () => {
    const { client, authStore } = await setupClient();
    vi.spyOn(authStore, 'getAccessToken').mockReturnValue('token-abc');
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ ok: true }));
    vi.stubGlobal('fetch', fetchMock);

    await client.request('/items', { skipAuth: true });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0];
    expect((init.headers as Record<string, string>).Authorization).toBeUndefined();
  });

  it('refreshes once and retries once on 401, returning the retried response on refresh success', async () => {
    const { client, authStore } = await setupClient();
    const getAccessToken = vi
      .spyOn(authStore, 'getAccessToken')
      .mockReturnValueOnce('expired-token')
      .mockReturnValue('fresh-token');
    const refresh = vi.spyOn(authStore, 'refresh').mockResolvedValue(true);
    const logout = vi.spyOn(authStore, 'logout').mockResolvedValue();
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ error: 'unauthorized' }, 401))
      .mockResolvedValueOnce(jsonResponse({ items: [] }, 200));
    vi.stubGlobal('fetch', fetchMock);

    const result = await client.request('/items');

    expect(result).toEqual({ items: [] });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(logout).not.toHaveBeenCalled();

    const [, secondInit] = fetchMock.mock.calls[1];
    expect((secondInit.headers as Record<string, string>).Authorization).toBe('Bearer fresh-token');
    expect(getAccessToken).toHaveBeenCalledTimes(2);
  });

  it('logs out and propagates the original 401 error when refresh fails', async () => {
    const { client, authStore } = await setupClient();
    vi.spyOn(authStore, 'getAccessToken').mockReturnValue('expired-token');
    const refresh = vi.spyOn(authStore, 'refresh').mockResolvedValue(false);
    const logout = vi.spyOn(authStore, 'logout').mockResolvedValue();
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ error: 'unauthorized' }, 401));
    vi.stubGlobal('fetch', fetchMock);

    await expect(client.request('/items')).rejects.toThrow(/401/);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(logout).toHaveBeenCalledTimes(1);
  });

  it('does not loop again if the retried request is also 401 (fetch<=2, refresh<=1)', async () => {
    const { client, authStore } = await setupClient();
    vi.spyOn(authStore, 'getAccessToken').mockReturnValue('token');
    const refresh = vi.spyOn(authStore, 'refresh').mockResolvedValue(true);
    const logout = vi.spyOn(authStore, 'logout').mockResolvedValue();
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ error: 'unauthorized' }, 401));
    vi.stubGlobal('fetch', fetchMock);

    await expect(client.request('/items')).rejects.toThrow(/401/);

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(logout).not.toHaveBeenCalled();
  });

  it('skipAuth requests never enter the refresh/retry dance, even on 401', async () => {
    const { client, authStore } = await setupClient();
    const refresh = vi.spyOn(authStore, 'refresh').mockResolvedValue(true);
    const logout = vi.spyOn(authStore, 'logout').mockResolvedValue();
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ error: 'unauthorized' }, 401));
    vi.stubGlobal('fetch', fetchMock);

    await expect(client.request('/items', { skipAuth: true })).rejects.toThrow(/401/);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(refresh).not.toHaveBeenCalled();
    expect(logout).not.toHaveBeenCalled();
  });

  it('getHealth() stays on the skipAuth path and never touches the auth store', async () => {
    const { authStore } = await setupClient();
    const getAccessToken = vi.spyOn(authStore, 'getAccessToken');
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ status: 'ok' }));
    vi.stubGlobal('fetch', fetchMock);

    const realClient = new ApiClient();
    const result = await realClient.getHealth();

    expect(result).toEqual({ status: 'ok' });
    expect(getAccessToken).not.toHaveBeenCalled();
    const [, init] = fetchMock.mock.calls[0];
    expect((init.headers as Record<string, string>).Authorization).toBeUndefined();
  });
});
