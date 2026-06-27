import { expect, test } from '@playwright/test';

test('home page loads and shows the heading', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'web' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Home' })).toBeVisible();
});
