/**
 * Auth state (Issue #41, task 2.3): a Pinia setup-store implementing
 * `AuthStoreState`/`AuthStoreActions` (`auth/types.ts`), backed by an
 * `oidc-client-ts` `UserManager` built from
 * `createOidcUserManagerSettings()` (`auth/oidcConfig.ts`).
 *
 * See `.kiro/specs/authn-authz/design.md` > Components and Interfaces >
 * Web / auth > AuthStore (State Management / Responsibilities & Constraints)
 * and the System Flows sequence diagram this store implements end to end
 * (login redirect -> code exchange -> bearer requests -> silent refresh on
 * 401 -> re-login prompt on refresh failure).
 *
 * Requirements: 3.1, 3.2, 3.4, 3.5, 4.1, 4.2 (requirements.md).
 *
 * Security (Requirement 5 / design.md Security Considerations): the access
 * token and the decoded user are held ONLY in module-local `ref`s created
 * inside this store's setup closure -- never written to `localStorage` /
 * `sessionStorage`. State does not survive a page reload (accepted
 * trade-off recorded in design.md's Open Questions/Risks).
 *
 * "Return to original page" contract (fills a gap `AuthStoreActions.login()`
 * leaves implicit, since it takes no parameters):
 * - `login()` reads the CURRENT route's `redirect` query parameter (via the
 *   `route` captured through `useRoute()` below) and passes it as
 *   `signinRedirect({ state: redirectTarget })`.
 * - `handleCallback()` reads the resulting `user.state` after a successful
 *   `signinRedirectCallback()` and calls `router.replace(state ?? '/')`.
 * - Task 3.4 (router guard, not built by this task) must redirect
 *   unauthenticated users to `/login?redirect=<originalPath>` for this to
 *   work end to end; task 3.2 (LoginView, not built by this task) just needs
 *   to call `authStore.login()` on mount without stripping the query string.
 *
 * Note on `useRoute()`/`useRouter()`: these are called ONCE, at the top of
 * this setup store's body (executed lazily on first `useAuthStore()` call,
 * never at module load), not re-invoked inside `login()`/`handleCallback()`
 * themselves. Pinia wraps a setup-store's setup() call in
 * `pinia._a.runWithContext(...)` (see `pinia/dist/pinia.mjs`), which is what
 * makes `inject()`-based composables usable here at all; calling them again
 * later from inside an action body (e.g. during a click handler) would run
 * outside that context and fail. `route` is a reactive object that always
 * reflects the CURRENT route, so reading `route.query.redirect` inside
 * `login()` still yields the value "at the moment it's called"; `router` is
 * a stable singleton, safe to call `.replace()` on at any time.
 */
import { computed, ref } from 'vue';
import { defineStore } from 'pinia';
import { useRoute, useRouter } from 'vue-router';
import { UserManager, type User } from 'oidc-client-ts';
import { cognitoHostedUiDomain, createOidcUserManagerSettings, region } from '../auth/oidcConfig';
import type { AuthenticatedUser, AuthStoreActions, AuthStoreState } from '../auth/types';

/**
 * Builds Cognito's proprietary logout URL. `oidc-client-ts`'s generic
 * `UserManager.signoutRedirect()` targets a standard OIDC
 * `end_session_endpoint`, which Cognito does not implement; Cognito instead
 * requires a direct browser navigation to its Hosted UI `/logout` endpoint.
 */
function buildCognitoLogoutUrl(
  clientId: string,
  postLogoutRedirectUri: string | undefined,
): string {
  return (
    `https://${cognitoHostedUiDomain}.auth.${region}.amazoncognito.com/logout` +
    `?client_id=${encodeURIComponent(clientId)}` +
    `&logout_uri=${encodeURIComponent(postLogoutRedirectUri ?? '')}`
  );
}

/** Derives the `AuthenticatedUser` (sub, scopes) from oidc-client-ts's `User`. */
function toAuthenticatedUser(oidcUser: User): AuthenticatedUser {
  return {
    sub: oidcUser.profile.sub,
    scopes: oidcUser.scope?.split(' ').filter(Boolean) ?? [],
  };
}

export const useAuthStore = defineStore('auth', () => {
  // Captured once at store-setup time -- see the module doc comment above
  // for why this is safe and why it is NOT re-invoked inside actions.
  const route = useRoute();
  const router = useRouter();

  const user = ref<AuthenticatedUser | null>(null);
  const accessToken = ref<string | null>(null);
  const error = ref<string | null>(null);
  const isAuthenticated = computed(() => user.value !== null);

  // Lazily constructed -- MUST NOT be built at module load or store-setup
  // time: `createOidcUserManagerSettings()` reads `window.location.origin`,
  // which does not exist during vite-ssg's Node/SSR prerender pass.
  let userManager: UserManager | undefined;
  function getUserManager(): UserManager {
    if (!userManager) {
      userManager = new UserManager(createOidcUserManagerSettings());
    }
    return userManager;
  }

  // Shared in-flight promise so concurrent `refresh()` callers don't each
  // trigger their own `signinSilent()` (design.md: AuthStore Concurrency
  // strategy).
  let refreshInFlight: Promise<boolean> | null = null;

  function applyUser(oidcUser: User): void {
    user.value = toAuthenticatedUser(oidcUser);
    accessToken.value = oidcUser.access_token;
  }

  function clearUser(): void {
    user.value = null;
    accessToken.value = null;
  }

  async function login(): Promise<void> {
    error.value = null;
    const redirectTarget = route.query.redirect;
    const state = typeof redirectTarget === 'string' ? redirectTarget : undefined;
    await getUserManager().signinRedirect({ state });
  }

  async function handleCallback(): Promise<void> {
    try {
      const oidcUser = await getUserManager().signinRedirectCallback();
      applyUser(oidcUser);
      error.value = null;
      const state = oidcUser.state as string | undefined;
      await router.replace(state ?? '/');
    } catch (err) {
      clearUser();
      error.value = err instanceof Error ? err.message : 'ログインに失敗しました';
    }
  }

  async function logout(): Promise<void> {
    const settings = getUserManager().settings;
    const logoutUrl = buildCognitoLogoutUrl(settings.client_id, settings.post_logout_redirect_uri);
    clearUser();
    window.location.href = logoutUrl;
  }

  async function refresh(): Promise<boolean> {
    if (refreshInFlight) {
      return refreshInFlight;
    }

    const promise = (async () => {
      try {
        const oidcUser = await getUserManager().signinSilent();
        if (!oidcUser) {
          clearUser();
          return false;
        }
        applyUser(oidcUser);
        return true;
      } catch {
        clearUser();
        return false;
      }
    })();

    refreshInFlight = promise;
    try {
      return await promise;
    } finally {
      refreshInFlight = null;
    }
  }

  function getAccessToken(): string | null {
    return accessToken.value;
  }

  // Compile-time proof this store's state/actions match `AuthStoreState`/
  // `AuthStoreActions` (`auth/types.ts`, which we must not modify) field for
  // field: unwrap the `Ref`/`ComputedRef` state via `.value` (Pinia does the
  // same unwrapping for real consumers of `useAuthStore()`), and check the
  // five action functions directly since they're plain functions already.
  // `error` is an intentional addition beyond this minimum contract, for
  // Requirement 3.5.
  const _stateCheck: AuthStoreState = { user: user.value, isAuthenticated: isAuthenticated.value };
  const _actionsCheck: AuthStoreActions = {
    login,
    handleCallback,
    logout,
    refresh,
    getAccessToken,
  };
  void _stateCheck;
  void _actionsCheck;

  return {
    user,
    isAuthenticated,
    error,
    login,
    handleCallback,
    logout,
    refresh,
    getAccessToken,
  };
});
