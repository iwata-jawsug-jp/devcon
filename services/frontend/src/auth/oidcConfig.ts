/**
 * `oidc-client-ts` `UserManager` configuration for Cognito Hosted UI login
 * (Authorization Code + PKCE), per `.kiro/specs/authn-authz/design.md`
 * (Technology Stack, File Structure Plan, System Flows, Security
 * Considerations). Task 2.3 (`stores/auth.ts`) constructs a `UserManager`
 * from this config; this module only wires the settings, it does not
 * implement any login/logout/refresh behavior itself.
 *
 * Env vars are all `VITE_`-prefixed and non-secret (Requirement 5.1) — see
 * `vite-env.d.ts` for their declared shape and `.env.example` for samples.
 */
import { InMemoryWebStorage, WebStorageStateStore, type UserManagerSettings } from 'oidc-client-ts';

/**
 * AWS region the Cognito User Pool lives in.
 * Falls back to the infra default (`infra/variables.tf` / `cognito_region`
 * in `services/backend/python/src/api/config.py`) when unset, so local dev
 * without a fully populated `.env` still resolves a sensible authority URL.
 *
 * Exported (task 2.3) so `stores/auth.ts` can build Cognito's proprietary
 * `/logout` URL (`https://{domain}.auth.{region}.amazoncognito.com/logout`)
 * from the exact same region source, instead of duplicating this fallback.
 */
export const region = import.meta.env.VITE_COGNITO_REGION ?? 'ap-northeast-1';

/** Cognito User Pool ID, e.g. "ap-northeast-1_xxxxxxxxx". */
const userPoolId = import.meta.env.VITE_COGNITO_USER_POOL_ID ?? '';

/** Public (no-secret) app client ID — `generate_secret = false` in infra/auth.tf. */
const clientId = import.meta.env.VITE_COGNITO_CLIENT_ID ?? '';

/**
 * Cognito Hosted UI domain prefix (`aws_cognito_user_pool_domain.hosted_ui`
 * in infra/auth.tf), e.g. "myapp-auth". Exposed here — not consumed by this
 * module — because `oidc-client-ts`'s `UserManager.signoutRedirect()`
 * targets a standard OIDC `end_session_endpoint`, which Cognito does not
 * implement; task 2.3 needs this raw domain value to build Cognito's
 * proprietary `/logout` URL itself (see CONCERNS in the task status report).
 */
export const cognitoHostedUiDomain = import.meta.env.VITE_COGNITO_DOMAIN ?? '';

/**
 * OIDC issuer/authority URL. Same shape as the backend's `cognito_issuer`
 * (`services/backend/python/src/api/config.py`):
 * `https://cognito-idp.{region}.amazonaws.com/{pool_id}`.
 */
export const cognitoAuthority = `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`;

/**
 * Scopes requested at sign-in. Must match `allowed_oauth_scopes` in
 * `infra/auth.tf`'s `aws_cognito_user_pool_client.web`: `openid` (required
 * for `oidc-client-ts` to receive an ID token) plus the resource server's
 * read/write scopes the API authorizes against (Requirement 2).
 */
const scope = 'openid api/items.read api/items.write';

/**
 * Builds the `UserManagerSettings` for the app's `UserManager`.
 *
 * A factory (rather than a module-level constant) so `redirect_uri` /
 * `post_logout_redirect_uri` — which depend on `window.location.origin` —
 * are resolved lazily at call time, not at module-import time. This keeps
 * the module safe to import from code that could in principle be reached
 * during `vite-ssg build`'s prerender pass (no `window` in that context),
 * even though nothing imports this module yet.
 *
 * `redirect_uri` / `post_logout_redirect_uri` must match the callback/logout
 * URLs `infra/auth.tf` registers on the Cognito app client
 * (`cognito_callback_urls` -> `/callback`, `cognito_logout_urls` -> `/login`).
 */
export function createOidcUserManagerSettings(): UserManagerSettings {
  const origin = window.location.origin;

  return {
    authority: cognitoAuthority,
    client_id: clientId,
    redirect_uri: `${origin}/callback`,
    post_logout_redirect_uri: `${origin}/login`,
    response_type: 'code',
    scope,

    // Security Considerations (design.md): access/refresh tokens must never
    // be written to localStorage/sessionStorage, memory only. `UserManager`'s
    // default `userStore` persists the signed-in `User` (which carries both
    // tokens) to `window.sessionStorage`. `InMemoryWebStorage` is
    // oidc-client-ts's own exported in-memory `Storage` implementation (never
    // touches a browser storage API), so wrapping it in `WebStorageStateStore`
    // satisfies the `StateStore` interface `userStore` expects while keeping
    // everything in memory. State does not survive a page reload, which is
    // the accepted trade-off recorded in design.md's Open Questions/Risks.
    userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),

    // `stateStore` (transient PKCE/CSRF state for the few seconds of the
    // redirect round-trip, not the long-lived token-bearing `User` object)
    // is intentionally left at its library default and NOT overridden here —
    // see CONCERNS in the task status report for the reasoning.
  };
}
