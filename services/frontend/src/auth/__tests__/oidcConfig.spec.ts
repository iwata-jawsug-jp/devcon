import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  cognitoAuthority,
  cognitoHostedUiDomain,
  createOidcUserManagerSettings,
} from '../oidcConfig';

describe('oidcConfig', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  // No .env is loaded in the test env, so every import of this module already
  // hits the "missing config" warning (#375) -- silence it here so the
  // pre-existing assertions below aren't testing console output by accident.
  // The warning's own behavior is covered separately below.
  beforeEach(() => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
  });

  it('builds the Cognito authority URL from region + pool id (same shape as the backend cognito_issuer)', () => {
    // No .env is loaded in the test env, so the region falls back to the
    // infra default and the (unset) pool id renders as an empty segment --
    // this still proves the URL shape is exactly
    // `https://cognito-idp.{region}.amazonaws.com/{pool_id}`.
    expect(cognitoAuthority).toBe('https://cognito-idp.ap-northeast-1.amazonaws.com/');
  });

  it('exposes the raw Hosted UI domain value for later logout-URL construction (task 2.3)', () => {
    expect(typeof cognitoHostedUiDomain).toBe('string');
  });

  it('builds redirect URIs from window.location.origin, matching the callback/logout routes registered in infra/auth.tf', () => {
    const settings = createOidcUserManagerSettings();

    expect(settings.redirect_uri).toBe(`${window.location.origin}/callback`);
    expect(settings.post_logout_redirect_uri).toBe(`${window.location.origin}/login`);
    expect(settings.response_type).toBe('code');
  });

  it('requests the openid + read/write resource-server scopes the API authorizes against', () => {
    const settings = createOidcUserManagerSettings();
    const scopes = settings.scope?.split(' ') ?? [];

    expect(scopes).toEqual(expect.arrayContaining(['openid', 'api/items.read', 'api/items.write']));
  });

  it('does not persist auth state to real browser storage (Requirement 5 / Security Considerations: memory only)', async () => {
    const settings = createOidcUserManagerSettings();
    const userStore = settings.userStore;
    expect(userStore).toBeDefined();

    await userStore?.set('oidc.user:test-authority:test-client', 'sentinel-token-payload');

    // The value must be retrievable through the store itself...
    await expect(userStore?.get('oidc.user:test-authority:test-client')).resolves.toBe(
      'sentinel-token-payload',
    );

    // ...but must never have touched real browser storage, which is the
    // concrete behavior that proves "memory only".
    expect(window.localStorage.getItem('oidc.user:test-authority:test-client')).toBeNull();
    expect(window.sessionStorage.getItem('oidc.user:test-authority:test-client')).toBeNull();
  });
});

describe('oidcConfig missing-config warning (#375)', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });

  it('warns when VITE_COGNITO_USER_POOL_ID / VITE_COGNITO_CLIENT_ID are empty', async () => {
    vi.stubEnv('VITE_COGNITO_USER_POOL_ID', '');
    vi.stubEnv('VITE_COGNITO_CLIENT_ID', '');
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    await import('../oidcConfig');

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('Cognito'));
  });

  it('does not warn once both are configured', async () => {
    vi.stubEnv('VITE_COGNITO_USER_POOL_ID', 'ap-northeast-1_example');
    vi.stubEnv('VITE_COGNITO_CLIENT_ID', 'example-client-id');
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    await import('../oidcConfig');

    expect(warnSpy).not.toHaveBeenCalled();
  });
});
