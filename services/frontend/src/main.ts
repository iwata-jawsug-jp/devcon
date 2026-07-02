import { ViteSSG } from 'vite-ssg';
import { createPinia } from 'pinia';
import { VueQueryPlugin } from '@tanstack/vue-query';
import App from './App.vue';
import { routes } from './router';
import './main.css';

export const createApp = ViteSSG(App, { routes }, ({ app }) => {
  app.use(createPinia());
  app.use(VueQueryPlugin);
});
