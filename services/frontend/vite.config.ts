/// <reference types="vitest/config" />
import { fileURLToPath, URL } from 'node:url';
import { defineConfig, loadEnv } from 'vite';
import vue from '@vitejs/plugin-vue';
import tailwindcss from '@tailwindcss/vite';
import { VitePWA } from 'vite-plugin-pwa';
import generateSitemap from 'vite-ssg-sitemap';

// https://vitejs.dev/config/
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const siteUrl = env.VITE_SITE_URL || 'http://localhost:5173';

  return {
    plugins: [
      vue(),
      tailwindcss(),
      VitePWA({
        registerType: 'autoUpdate',
        includeAssets: ['icon.svg', 'apple-touch-icon.png'],
        manifest: {
          name: 'devcon',
          short_name: 'devcon',
          description:
            'devcon — Dev Container 上で構築する Vite + Vue 3 SPA / FastAPI モノレポのテンプレート。',
          theme_color: '#3d5fce',
          background_color: '#ffffff',
          display: 'standalone',
          start_url: '/',
          icons: [
            { src: 'pwa-192x192.png', sizes: '192x192', type: 'image/png' },
            { src: 'pwa-512x512.png', sizes: '512x512', type: 'image/png' },
            {
              src: 'pwa-maskable-512x512.png',
              sizes: '512x512',
              type: 'image/png',
              purpose: 'maskable',
            },
          ],
        },
        workbox: {
          // Precache only the built static shell (JS/CSS/HTML/icons). No
          // runtimeCaching for `/api/*` here on purpose — once authenticated
          // app routes exist (#41), caching API responses in the service
          // worker risks serving stale or wrong-user data across sessions.
          // Revisit this file's `workbox` config at that point.
          globPatterns: ['**/*.{js,css,html,svg,png,ico,webmanifest}'],
          // Activate a new SW immediately instead of waiting for all tabs on
          // the old version to close — pairs with registerType: 'autoUpdate'
          // so users always get the latest deploy.
          clientsClaim: true,
          skipWaiting: true,
        },
      }),
    ],
    resolve: {
      alias: {
        '@': fileURLToPath(new URL('./src', import.meta.url)),
      },
    },
    server: {
      proxy: {
        '/api': {
          target: 'http://localhost:8000',
          changeOrigin: true,
        },
      },
    },
    ssgOptions: {
      // Every current route is a public page, so prerender all of them. Once
      // authenticated app routes exist (#41), exclude them here so only the
      // public LP stays build-time prerendered and the rest is CSR SPA — e.g.
      // `includedRoutes: (paths) => paths.filter((p) => !p.startsWith('/app'))`.
      onFinished() {
        generateSitemap({ hostname: siteUrl });
      },
    },
    test: {
      environment: 'jsdom',
      globals: true,
      include: ['src/**/*.{test,spec}.ts'],
      exclude: ['e2e/**', 'node_modules/**'],
      coverage: {
        provider: 'v8',
        reporter: ['text', 'html'],
        include: ['src/**/*.{ts,vue}'],
        exclude: ['src/api/schema.ts', 'src/main.ts', 'src/**/*.spec.ts'],
        // Current actual coverage is ~85-96% across all four; these thresholds
        // sit a little below that as a real regression gate (#306), not the
        // near-no-op 35/35/45/55 floor that let coverage silently erode.
        thresholds: {
          lines: 90,
          statements: 90,
          functions: 90,
          branches: 80,
        },
      },
    },
  };
});
