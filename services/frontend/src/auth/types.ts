/**
 * Type contracts for the authentication domain (Issue #41).
 *
 * These are the EXACT shapes specified in `.kiro/specs/authn-authz/design.md`
 * (Components and Interfaces > Web / auth > AuthStore > State Management).
 * `stores/auth.ts` (task 2.3) implements a Pinia store against these
 * contracts — this module only declares the types, it does not implement
 * any behavior.
 */

/** The authenticated user, derived from the verified Cognito access token. */
export interface AuthenticatedUser {
  sub: string;
  scopes: string[];
}

/** Reactive state exposed by the auth store. */
export interface AuthStoreState {
  user: AuthenticatedUser | null;
  /** Computed: `user !== null`. */
  isAuthenticated: boolean;
}

/** Actions exposed by the auth store. */
export interface AuthStoreActions {
  /** Redirects to the Cognito Hosted UI (`UserManager.signinRedirect()`). */
  login(): Promise<void>;
  /** Completes the OIDC redirect callback (code exchange). */
  handleCallback(): Promise<void>;
  /** Clears in-memory auth state and redirects to Cognito's logout endpoint. */
  logout(): Promise<void>;
  /**
   * Attempts a silent token refresh.
   * @returns `true` on success, `false` on failure (caller decides whether to log out).
   */
  refresh(): Promise<boolean>;
  /** Returns the current access token, or `null` if unauthenticated. Never persisted. */
  getAccessToken(): string | null;
}
