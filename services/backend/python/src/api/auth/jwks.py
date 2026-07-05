"""JWKS signing-key resolution for Cognito-issued JWTs.

Wraps PyJWT's own ``PyJWKClient`` — which already provides TTL-based JWKS
caching (default 300s) and automatic re-fetch on an unknown ``kid`` — so this
module intentionally contains no hand-rolled caching or HTTP logic (design.md
JwksVerifier Responsibilities & Constraints: "PyJWT標準機能、独自実装なし").

Only resolves the signing key for a raw token string; JWT decoding/claims
verification (``iss``/``client_id``/``token_use``/``exp``) is out of scope
here and belongs to task 2.1's ``get_current_user`` dependency.
"""

from functools import lru_cache

import jwt

from api.config import get_settings


def _jwks_uri(user_pool_id: str, region: str) -> str:
    """Build the Cognito JWKS endpoint URI from a user pool id and region."""
    return f"https://cognito-idp.{region}.amazonaws.com/{user_pool_id}/.well-known/jwks.json"


class JwksVerifier:
    """Resolves the signing key for a JWT from a Cognito JWKS endpoint.

    A thin wrapper around :class:`jwt.PyJWKClient`; intended to be
    constructed once per process (see :func:`get_jwks_verifier`) and shared
    across requests.
    """

    def __init__(self, jwks_uri: str) -> None:
        self._client = jwt.PyJWKClient(jwks_uri)

    def get_signing_key(self, token: str) -> jwt.PyJWK:
        """Return the signing key matching *token*'s ``kid`` header.

        Delegates to ``PyJWKClient.get_signing_key_from_jwt``, which reads
        the unverified header to extract ``kid`` and, if the key isn't in
        the cached JWK Set, refreshes the set once from the JWKS endpoint
        before giving up.
        """
        return self._client.get_signing_key_from_jwt(token)


@lru_cache
def get_jwks_verifier() -> JwksVerifier:
    """Return a process-wide cached :class:`JwksVerifier` instance.

    Mirrors the ``get_settings()`` pattern in ``config.py``: an
    ``lru_cache``-decorated factory stands in for a module-level singleton
    while still being overridable in tests.
    """
    settings = get_settings()
    uri = _jwks_uri(settings.cognito_user_pool_id, settings.cognito_region)
    return JwksVerifier(jwks_uri=uri)
