import { expect, test } from '@playwright/test';

// Runs against `vite preview` (see playwright.config.ts) — the service
// worker only registers in a production build, not the Vite dev server.
// Lighthouse's PWA category (installable-manifest / service-worker audits)
// was removed upstream (no longer present as of lighthouse@12), so this is
// the closest automated equivalent to the original "Lighthouse PWA check"
// completion criterion for #80.

test('exposes a valid, installable web app manifest', async ({ page, baseURL }) => {
  const response = await page.goto('/');
  expect(response?.ok()).toBe(true);

  const manifestHref = await page.locator('link[rel="manifest"]').getAttribute('href');
  expect(manifestHref).toBeTruthy();

  const manifestResponse = await page.request.get(new URL(manifestHref!, baseURL).toString());
  expect(manifestResponse.ok()).toBe(true);

  const manifest = await manifestResponse.json();
  expect(manifest.name).toBeTruthy();
  expect(manifest.display).toBe('standalone');
  expect(manifest.icons.some((icon: { sizes: string }) => icon.sizes === '512x512')).toBe(true);
  expect(manifest.icons.some((icon: { purpose?: string }) => icon.purpose === 'maskable')).toBe(
    true,
  );
});

test('registers an active service worker', async ({ page }) => {
  await page.goto('/');

  await page.waitForFunction(
    async () => {
      const registrations = await navigator.serviceWorker.getRegistrations();
      return registrations.some((registration) => registration.active !== null);
    },
    { timeout: 10_000 },
  );
});
