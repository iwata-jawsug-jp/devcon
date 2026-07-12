import { defineConfig, devices } from '@playwright/test';

// See https://playwright.dev/docs/test-configuration
export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: 'html',
  use: {
    trace: 'on-first-retry',
  },
  projects: [
    {
      name: 'chromium',
      testIgnore: ['**/pwa.spec.ts', '**/live-smoke/**'],
      use: { ...devices['Desktop Chrome'], baseURL: 'http://localhost:5173' },
    },
    {
      // The service worker only registers in a production build, not the
      // Vite dev server, so this project runs against `vite preview`
      // instead (see #80).
      name: 'chromium-pwa',
      testMatch: '**/pwa.spec.ts',
      use: { ...devices['Desktop Chrome'], baseURL: 'http://localhost:4173' },
    },
    {
      // The "4th gate" (#376, ADR-0008): runs against a real deployed
      // environment (SMOKE_BASE_URL), not a local dev server, so it always
      // records trace/screenshot/video for post-mortem diagnosis and skips
      // entirely when SMOKE_BASE_URL is unset (see live-smoke.spec.ts).
      name: 'live-smoke',
      testMatch: '**/live-smoke/**/*.spec.ts',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: process.env.SMOKE_BASE_URL,
        trace: 'on',
        screenshot: 'on',
        video: 'on',
      },
    },
  ],
  // Skip booting the local dev server / preview build entirely when running
  // against a real deployed environment (SMOKE_BASE_URL set) -- the
  // live-smoke project doesn't need either, and CI's smoke-test job
  // shouldn't pay for or depend on an unrelated local build succeeding.
  webServer: process.env.SMOKE_BASE_URL
    ? undefined
    : [
        {
          command: 'npm run dev',
          url: 'http://localhost:5173',
          reuseExistingServer: !process.env.CI,
        },
        {
          command: 'npm run build && npm run preview',
          url: 'http://localhost:4173',
          reuseExistingServer: !process.env.CI,
          timeout: 60_000,
        },
      ],
});
