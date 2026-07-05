/// <reference types="vite/client" />

// Build-time env vars (Issue #41, authn-authz). All VITE_-prefixed and
// non-secret per Requirement 5.1 — see services/frontend/.env.example.
interface ImportMetaEnv {
  /** Cognito User Pool ID, e.g. "ap-northeast-1_xxxxxxxxx". */
  readonly VITE_COGNITO_USER_POOL_ID?: string;
  /** AWS region the Cognito User Pool lives in, e.g. "ap-northeast-1". */
  readonly VITE_COGNITO_REGION?: string;
  /** Public (no-secret) app client ID registered on the User Pool. */
  readonly VITE_COGNITO_CLIENT_ID?: string;
  /**
   * Cognito Hosted UI domain (the `aws_cognito_user_pool_domain.hosted_ui`
   * prefix from infra/auth.tf), e.g. "myapp-auth". Used to build the Hosted
   * UI base URL for login/logout — Cognito does not expose a standard OIDC
   * `end_session_endpoint`, so this is consumed directly (see oidcConfig.ts).
   */
  readonly VITE_COGNITO_DOMAIN?: string;
}
