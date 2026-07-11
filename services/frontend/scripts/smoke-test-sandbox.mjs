#!/usr/bin/env node
// Post-deploy smoke test (issue #373): the "4th gate" alongside fmt/lint/
// test/security -- none of those layers ever exercise a real browser
// completing an actual Cognito Hosted UI login against a deployed
// environment, so a whole class of real-environment-only defects (#365
// CSP blocking the OIDC discovery fetch, #367 missing VITE_COGNITO_* at
// build time, #369 missing cognito-idp VPC endpoint + missing
// API_COGNITO_* on the backend) went undetected by CI until a human ran
// this exact flow by hand during issue #364's verification.
//
// Deliberately minimal: log in for real, then confirm exactly one
// authenticated API call succeeds. It is NOT a business-scenario test
// (that's what a feature's own manual/E2E verification is for) -- its
// only job is "can anyone actually log in and use this deployment at
// all", so it stays fast and has as few moving parts as possible.
//
// Uses a fixed, pre-provisioned Cognito test user (SMOKE_TEST_EMAIL /
// SMOKE_TEST_PASSWORD) rather than creating one per run: the CI deploy
// role intentionally has no cognito-idp:Admin* permissions (see
// infra/bootstrap/main.tf), and granting them would be a self-service
// IAM expansion this project's operating rules reserve for a human to
// review (docs/sandbox.md). Provisioning that user is a one-time,
// human-run step -- see docs/sandbox.md for the exact aws cognito-idp
// admin-create-user / admin-set-user-password commands.
//
// The app keeps the access token only in an in-memory Pinia ref, never in
// localStorage/sessionStorage/cookies (stores/auth.ts) -- and as of #373,
// main has no protected view that issues an authenticated API call on its
// own for us to piggyback on. So instead of relying on app UI, this script
// captures the access_token directly out of the Cognito OAuth2 token-
// exchange response (POST .../oauth2/token, triggered by
// AuthCallbackView's handleCallback()) and uses it to make the
// authenticated request itself via Playwright's APIRequestContext. This
// stays valid regardless of which (if any) protected views exist later.
import { chromium } from 'playwright';

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`FAIL missing required env var: ${name}`);
    process.exit(1);
  }
  return value;
}

const BASE_URL = requireEnv('SMOKE_BASE_URL').replace(/\/$/, '');
const EMAIL = requireEnv('SMOKE_TEST_EMAIL');
const PASSWORD = requireEnv('SMOKE_TEST_PASSWORD');
// Any endpoint requiring only a read scope works; /api/items is the
// oldest, most stable one and carries no order-management-specific
// assumptions about what's deployed.
const SMOKE_TARGET_PATH = process.env.SMOKE_TARGET_PATH ?? '/api/items';

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

// A substring check here (`url.includes('amazoncognito.com')`) is an
// incomplete host check -- CodeQL js/incomplete-url-substring-sanitization,
// flagged by the public mirror's Code scanning: a URL like
// `https://evil.example/amazoncognito.com` would pass it. Parse the URL and
// check the actual hostname suffix instead.
function isCognitoHostedUiUrl(url) {
  try {
    return new URL(url).hostname.endsWith('.amazoncognito.com');
  } catch {
    return false;
  }
}

// Our SPA's /login and /callback routes do their real work (the redirect
// to Cognito, and the code-exchange redirect back) inside a Vue
// onMounted hook, which runs AFTER the browser's 'load' event a
// page.goto()/waitForNavigation() resolves on -- so page.url() can still
// show one of these transitional routes for a moment. Wait until we've
// moved past both before deciding what state we're in.
async function waitPastTransitionalRoutes(page) {
  while (
    page.url().startsWith(`${BASE_URL}/login`) ||
    page.url().startsWith(`${BASE_URL}/callback`)
  ) {
    await page.waitForURL(
      (url) =>
        !url.toString().startsWith(`${BASE_URL}/login`) &&
        !url.toString().startsWith(`${BASE_URL}/callback`),
      { timeout: 15000 },
    );
  }
}

async function poll(predicate, { timeout = 30000, interval = 200 } = {}) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, interval));
  }
  throw new Error('timed out waiting for condition');
}

async function main() {
  const browser = await chromium.launch();
  const context = await browser.newContext();
  const page = await context.newPage();

  const consoleErrors = [];
  page.on('console', (msg) => {
    if (msg.type() === 'error') consoleErrors.push(msg.text());
  });

  // A persistent listener, not page.waitForResponse() registered around the
  // click below: waitForResponse can silently miss a response that lands
  // partway through a multi-hop cross-origin redirect chain (Hosted UI ->
  // /callback -> token POST), a failure mode hit while building the manual
  // verification script this is based on. Poll the captured value instead.
  let tokenBody = null;
  page.on('response', (res) => {
    if (tokenBody || !res.url().includes('/oauth2/token') || res.request().method() !== 'POST') {
      return;
    }
    res
      .json()
      .then((body) => {
        tokenBody = body;
      })
      .catch(() => {});
  });

  log('navigating to /login to trigger the Cognito Hosted UI redirect');
  await page.goto(`${BASE_URL}/login`, { waitUntil: 'load' });
  await waitPastTransitionalRoutes(page);

  if (!isCognitoHostedUiUrl(page.url())) {
    throw new Error(`expected a redirect to Cognito Hosted UI, landed on ${page.url()} instead`);
  }
  log('interactive login at', page.url());
  // Cognito's hosted UI renders duplicate (mobile/desktop) form markup
  // sharing the same name/id, with only one visible -- `:visible` picks it.
  await page.fill('input[name="username"]:visible', EMAIL);
  await page.fill('input[name="password"]:visible', PASSWORD);
  await page.click('input[name="signInSubmitButton"]:visible');

  await poll(() => tokenBody, { timeout: 30000 });
  const accessToken = tokenBody.access_token;
  if (!accessToken) {
    throw new Error(`token exchange response had no access_token: ${JSON.stringify(tokenBody)}`);
  }
  log('captured access_token from the OAuth2 token exchange');

  await waitPastTransitionalRoutes(page);
  log('post-login landed on', page.url());

  const response = await page.request.get(`${BASE_URL}${SMOKE_TARGET_PATH}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const apiStatus = response.status();
  log(`GET ${SMOKE_TARGET_PATH} -> ${apiStatus}`);

  await browser.close();

  if (apiStatus >= 300) {
    console.error(`FAIL: GET ${SMOKE_TARGET_PATH} returned ${apiStatus}`);
    if (consoleErrors.length > 0) {
      console.error('Browser console errors during the run:');
      for (const e of consoleErrors) console.error(`  ${e}`);
    }
    process.exit(1);
  }

  console.log(`OK: logged in and GET ${SMOKE_TARGET_PATH} returned ${apiStatus}`);
}

main().catch((err) => {
  console.error('FAIL:', err);
  process.exit(1);
});
