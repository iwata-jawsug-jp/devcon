import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

test('home page loads and shows the heading', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'devcon' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Home' })).toBeVisible();
});

test('home page has no automatically detectable accessibility violations', async ({ page }) => {
  await page.goto('/');
  const results = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'])
    .analyze();
  expect(results.violations, JSON.stringify(results.violations, null, 2)).toEqual([]);
});
