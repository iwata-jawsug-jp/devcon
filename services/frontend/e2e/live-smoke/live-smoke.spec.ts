// The "4th gate" (issue #376, superseding #373's raw script -- see
// ADR-0008): a whole class of real-environment-only defects (#365 CSP
// blocking the OIDC discovery fetch, #367 missing VITE_COGNITO_* at build
// time, #369 missing cognito-idp VPC endpoint + missing API_COGNITO_* on the
// backend) broke the actual login -> authenticated-API-call path while every
// existing gate (unit/integration tests, all of which mock auth) stayed
// green. This scenario exercises that exact path against a real deployed
// environment with a real headless-Chromium Cognito Hosted UI login.
//
// Deliberately minimal (S1-S3, issue #376's design table, +S4 for #439): it is NOT a
// business-scenario test -- its only job is "can anyone actually log in and
// use this deployment at all", so it stays fast (~5 minutes) and has as few
// moving parts as possible.
import { expect, test } from './fixtures';

test.skip(
  !process.env.SMOKE_BASE_URL,
  'SMOKE_BASE_URL is not set -- skipping the live smoke test (see docs/sandbox.md).',
);

test('real Cognito login, an authenticated write, and cross-session consistency', async ({
  page,
  baseURL,
  browser,
  accessToken,
}) => {
  await test.step('S1: Cognito Hosted UI login issues a usable access token', async () => {
    // The accessToken fixture already drove the full login redirect chain;
    // reaching this point with a truthy token IS the S1 assertion.
    expect(accessToken).toBeTruthy();
  });

  const itemName = `e2e-live-smoke-${Date.now()}`;
  let createdId: number;

  await test.step('S2: an authenticated write succeeds (POST /api/items, write scope)', async () => {
    const response = await page.request.post('/api/items', {
      headers: { Authorization: `Bearer ${accessToken}` },
      data: { name: itemName, description: 'created by the live-smoke E2E gate (#376)' },
    });
    expect(response.status(), await response.text()).toBe(201);
    const body = await response.json();
    createdId = body.id;
  });

  await test.step('S3: the write is visible from a separate session (new browser context)', async () => {
    // A fresh browser context -- separate cookie jar / storage / service
    // worker -- rules out "it only worked because of state left over from
    // S2's context" and forces a real network round trip through
    // CloudFront -> ALB -> ECS -> RDS, catching session-isolation, caching,
    // and CloudFront-routing regressions.
    const freshContext = await browser.newContext({ baseURL });
    try {
      const response = await freshContext.request.get(`/api/items/${createdId!}`, {
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      expect(response.status(), await response.text()).toBe(200);
      const body = await response.json();
      expect(body.name).toBe(itemName);
    } finally {
      await freshContext.close();
    }
  });

  await test.step('S4: a nonexistent /api/* path surfaces its real 404, not the SPA fallback (#439)', async () => {
    // Before #439, CloudFront's distribution-wide custom_error_response
    // (403/404 -> 200 + /index.html) applied to the /api/* behavior too, so
    // this request would have come back 200 with the SPA's HTML instead of
    // the API's actual 404 -- exactly the masking that hid a real authz
    // regression behind a "200" in devcon-test#19/#20. A missing-scope 403
    // isn't independently testable here yet: every scope this app defines
    // (api/items.read, api/items.write) is already requested by the
    // frontend's login flow (oidcConfig.ts), so the live-smoke token always
    // holds both -- add a case here once a scope-gated resource exists that
    // the login flow doesn't request every scope for.
    const response = await page.request.get('/api/this-route-does-not-exist');
    expect(response.status(), await response.text()).toBe(404);
    expect(response.headers()['content-type'] ?? '').not.toContain('text/html');
  });
});
