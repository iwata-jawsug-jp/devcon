import { ViteSSG } from 'vite-ssg';
import { createPinia } from 'pinia';
import { VueQueryPlugin } from '@tanstack/vue-query';
import App from './App.vue';
import { authGuard, routes } from './router';
import './main.css';

export const createApp = ViteSSG(App, { routes }, ({ app, router }) => {
  app.use(createPinia());
  app.use(VueQueryPlugin);
  // RouterGuard (task 3.4): redirects unauthenticated users away from any
  // route with `meta.requiresAuth` to /login. See router/index.ts's
  // `authGuard` doc comment. No current route sets `meta.requiresAuth`, so
  // this never fires during vite-ssg's prerender pass.
  router.beforeEach(authGuard);
});
