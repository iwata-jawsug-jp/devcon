import type { NavigationGuard, RouteLocationNormalized, RouteRecordRaw } from 'vue-router';
import HomeView from '../views/HomeView.vue';
import LoginView from '../views/LoginView.vue';
import AuthCallbackView from '../views/AuthCallbackView.vue';
import { useAuthStore } from '../stores/auth';

declare module 'vue-router' {
  interface RouteMeta {
    /**
     * Task 3.4 (RouterGuard, requirements.md 3.1): routes that set this to
     * `true` are blocked for unauthenticated users -- see `authGuard` below.
     * None of this app's current routes (`home`, `login`, `callback`) set
     * this; it exists for future protected routes to opt into.
     */
    requiresAuth?: boolean;
  }
}

/**
 * Route definitions only — vite-ssg builds the actual router (see main.ts),
 * so it needs the raw route records rather than a constructed router instance.
 *
 * `/login` and `/callback` paths MUST exactly match `infra/auth.tf`'s
 * Cognito `callback_urls` (`/callback`) / `logout_urls` (`/login`).
 */
export const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'home',
    component: HomeView,
  },
  {
    path: '/login',
    name: 'login',
    component: LoginView,
  },
  {
    path: '/callback',
    name: 'callback',
    component: AuthCallbackView,
  },
];

/**
 * RouterGuard (task 3.4; requirements.md 3.1; design.md Components and
 * Interfaces / Web / router "RouterGuard"): a generic `beforeEach` guard,
 * registered by `main.ts`, that blocks navigation to any route declaring
 * `meta.requiresAuth` while the user is unauthenticated and redirects to
 * `/login`, carrying the original destination's full path (including its
 * own query string) as the `redirect` query param.
 *
 * The `redirect` query key is a fixed contract with task 2.3's
 * `stores/auth.ts`: `login()` reads `route.query.redirect` and passes it as
 * the OIDC `state`, and `handleCallback()` navigates back to it on success --
 * this guard's only job is producing that query param, not consuming it.
 *
 * Returns a route location object (rather than calling the deprecated
 * `next()` callback) per Vue Router 4/5's modern `NavigationGuard` style.
 */
export const authGuard: NavigationGuard = (to: RouteLocationNormalized) => {
  if (to.meta.requiresAuth && !useAuthStore().isAuthenticated) {
    return { name: 'login', query: { redirect: to.fullPath } };
  }
  return true;
};
