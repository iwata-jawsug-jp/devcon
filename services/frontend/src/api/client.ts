import type { components, paths } from './schema';
import { useAuthStore } from '../stores/auth';

/**
 * Base path for all API calls. In dev the Vite server proxies `/api` to the
 * backend (see vite.config.ts). Override via the `VITE_API_BASE` env var.
 */
const API_BASE = import.meta.env.VITE_API_BASE ?? '/api';

export type HealthResponse = components['schemas']['HealthStatus'];

/**
 * `request()` options. See `.kiro/specs/authn-authz/design.md` > Components
 * and Interfaces > Web / api > ApiClient（変更） (Requirements 4.1, 4.2).
 */
export interface RequestOptions extends RequestInit {
  /** login/callback等、Authorizationヘッダーを付与しないリクエスト用 */
  skipAuth?: boolean;
}

/**
 * Thrown by `ApiClient#request` on a non-OK response. `body` is the parsed
 * JSON error payload when the response had one (e.g. backend's
 * `{ detail, request_id }` on a 500 -- see `exception_handlers.py`), so
 * callers can branch on it instead of parsing `message` (#304).
 */
export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly body?: unknown,
  ) {
    super(`API request failed: ${status} ${statusText}`);
    this.name = 'ApiError';
  }
}

/**
 * The single, typed entry point for talking to the backend API.
 *
 * Components MUST go through this client rather than calling `fetch` directly.
 * `paths` is imported from the generated `schema.ts` so request/response types
 * can be tightened as the OpenAPI schema grows.
 */
export type GreetingResponse = components['schemas']['Greeting'];

export class ApiClient {
  constructor(private readonly baseUrl: string = API_BASE) {}

  /**
   * Attaches `Authorization: Bearer <token>` (unless `skipAuth`) and, on a
   * 401 response, tries exactly one silent refresh + retry before falling
   * back to logout + propagating the original error. `useAuthStore()` is
   * called fresh on every invocation (never cached on `this`) so this works
   * regardless of when/how many Pinia instances exist (see design.md's
   * Implementation Notes and the SSR/prerender note in the class doc above).
   */
  private async request<T>(path: string, init?: RequestOptions): Promise<T> {
    const { skipAuth = false, ...requestInit } = init ?? {};

    const buildHeaders = (): Record<string, string> => {
      const headers: Record<string, string> = {
        Accept: 'application/json',
        ...(requestInit.headers as Record<string, string> | undefined),
      };
      if (!skipAuth) {
        const token = useAuthStore().getAccessToken();
        if (token) {
          headers.Authorization = `Bearer ${token}`;
        }
      }
      return headers;
    };

    const doFetch = (): Promise<Response> =>
      fetch(`${this.baseUrl}${path}`, { ...requestInit, headers: buildHeaders() });

    let response = await doFetch();

    if (!response.ok && response.status === 401 && !skipAuth) {
      // Exactly one refresh-and-retry attempt (無限リトライしない). If this
      // retried request is ALSO a 401, we do not loop again -- we simply
      // fall through to the throw below.
      const authStore = useAuthStore();
      const refreshed = await authStore.refresh();
      if (refreshed) {
        response = await doFetch();
      } else {
        await authStore.logout();
      }
    }

    if (!response.ok) {
      const body = await response.json().catch(() => undefined);
      throw new ApiError(response.status, response.statusText, body);
    }
    return (await response.json()) as T;
  }

  /**
   * GET /api/health -> { status: "ok" }.
   *
   * `skipAuth: true`: `health` stays unauthenticated (Requirement 1.4) and is
   * polled by infra health checks that never hold a token, so there is
   * nothing to attach/refresh. This also keeps `getHealth()` from touching
   * `useAuthStore()`/Pinia at all, so existing callers (e.g. `HealthBadge`,
   * and vite-ssg's prerender of `/`) are unaffected by this task.
   *
   * `signal` forwards TanStack Query's cancellation signal (`queryFn({
   * signal })`, see `queries.ts`) through to the underlying `fetch`, so an
   * aborted query actually cancels the in-flight request (#304).
   */
  getHealth(options?: { signal?: AbortSignal }): Promise<HealthResponse> {
    return this.request<HealthResponse>('/health', { skipAuth: true, signal: options?.signal });
  }

  getGreeting(name: string, options?: { signal?: AbortSignal }): Promise<GreetingResponse> {
    const query = new URLSearchParams({ name }).toString();
    return this.request<GreetingResponse>(`/greeting?${query}`, {
      skipAuth: true,
      signal: options?.signal,
    });
  }
}

// Reference the generated schema so its types stay wired into the client.
export type ApiPaths = paths;

export const apiClient = new ApiClient();
