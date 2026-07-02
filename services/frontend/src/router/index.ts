import type { RouteRecordRaw } from 'vue-router';
import HomeView from '../views/HomeView.vue';

/**
 * Route definitions only — vite-ssg builds the actual router (see main.ts),
 * so it needs the raw route records rather than a constructed router instance.
 */
export const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'home',
    component: HomeView,
  },
];
