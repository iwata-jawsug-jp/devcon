import { expect, test as base, type Page } from '@playwright/test';

// A substring host check (`url.includes('amazoncognito.com')`) is an
// incomplete sanitization -- CodeQL js/incomplete-url-substring-sanitization,
// fixed the same way in the #373 script this fixture supersedes. Parse the
// URL and check the actual hostname suffix instead.
function isCognitoHostedUiUrl(url: string): boolean {
  try {
    return new URL(url).hostname.endsWith('.amazoncognito.com');
  } catch {
    return false;
  }
}

// Our SPA's /login and /callback routes do their real work (the redirect to
// Cognito, and the code-exchange redirect back) inside a Vue onMounted hook,
// which runs AFTER the browser's 'load' event a goto()/waitForNavigation()
// resolves on -- so page.url() can still show one of these transitional
// routes for a moment. Wait until we've moved past both before deciding what
// state we're in.
async function waitPastTransitionalRoutes(page: Page, baseURL: string): Promise<void> {
  while (
    page.url().startsWith(`${baseURL}/login`) ||
    page.url().startsWith(`${baseURL}/callback`)
  ) {
    await page.waitForURL(
      (url) =>
        !url.toString().startsWith(`${baseURL}/login`) &&
        !url.toString().startsWith(`${baseURL}/callback`),
      { timeout: 15000 },
    );
  }
}

type LiveSmokeFixtures = {
  /**
   * A real Cognito access_token obtained by driving the actual Hosted UI
   * login flow (SMOKE_TEST_EMAIL / SMOKE_TEST_PASSWORD). The app keeps its
   * access token only in an in-memory Pinia ref (stores/auth.ts), never in
   * localStorage/sessionStorage/cookies, so this fixture can't just read it
   * out of browser storage -- it captures the token directly from the
   * Cognito OAuth2 token-exchange response instead (promoted from the #364
   * verification script's design, per #376).
   */
  accessToken: string;
};

export const test = base.extend<LiveSmokeFixtures>({
  accessToken: async ({ page, baseURL }, use) => {
    if (!baseURL) {
      throw new Error('baseURL is not set (SMOKE_BASE_URL) -- see the live-smoke project config.');
    }
    const email = process.env.SMOKE_TEST_EMAIL;
    const password = process.env.SMOKE_TEST_PASSWORD;
    if (!email || !password) {
      throw new Error('SMOKE_TEST_EMAIL / SMOKE_TEST_PASSWORD must both be set.');
    }

    // A persistent listener, not page.waitForResponse() registered around
    // the click below: waitForResponse can silently miss a response that
    // lands partway through a multi-hop cross-origin redirect chain (Hosted
    // UI -> /callback -> token POST), a failure mode hit while building the
    // #364 verification script this is based on. Poll the captured value
    // instead (via expect.poll below).
    let tokenBody: { access_token?: string } | null = null;
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

    await page.goto(`${baseURL}/login`, { waitUntil: 'load' });
    await waitPastTransitionalRoutes(page, baseURL);

    if (!isCognitoHostedUiUrl(page.url())) {
      throw new Error(`expected a redirect to Cognito Hosted UI, landed on ${page.url()} instead`);
    }

    // Cognito's hosted UI renders duplicate (mobile/desktop) form markup
    // sharing the same name/id, with only one visible -- `:visible` picks
    // the right one.
    await page.fill('input[name="username"]:visible', email);
    await page.fill('input[name="password"]:visible', password);
    await page.click('input[name="signInSubmitButton"]:visible');

    await expect.poll(() => tokenBody, { timeout: 30000 }).toBeTruthy();
    const accessToken = tokenBody!.access_token;
    if (!accessToken) {
      throw new Error(`token exchange response had no access_token: ${JSON.stringify(tokenBody)}`);
    }

    await waitPastTransitionalRoutes(page, baseURL);

    await use(accessToken);
  },
});

export { expect };
