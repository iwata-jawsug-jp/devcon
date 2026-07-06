"""Authentication/authorization dependencies for FastAPI routes.

Implements the AuthDependency component from design.md:

- ``get_current_user`` (Task 2.1): resolve the caller's ``AuthenticatedUser``
  from a verified Cognito access token, or raise 401 for any failure (missing
  header, bad signature, expired token, wrong token type, or a client_id
  mismatch).
- ``require_scope`` (Task 2.2): a dependency factory that, given a scope
  string, builds on top of ``get_current_user`` (via ``Depends()``, not by
  reimplementing it) and additionally raises 403 when the resolved user's
  scopes don't include the required scope.
"""

from collections.abc import Awaitable, Callable
from typing import Annotated

import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from api.auth.jwks import get_jwks_verifier
from api.auth.schemas import AuthenticatedUser
from api.config import get_settings

# A pure resource server extracts bearer tokens; it does not issue them via a
# password/client-credentials grant, so HTTPBearer (not OAuth2PasswordBearer)
# is the right primitive. ``auto_error=True`` (the default) already raises a
# 401 when the ``Authorization`` header is missing or malformed, so that case
# needs no bespoke handling here.
_bearer_scheme = HTTPBearer()
BearerCredentialsDep = Annotated[HTTPAuthorizationCredentials, Depends(_bearer_scheme)]


async def get_current_user(credentials: BearerCredentialsDep) -> AuthenticatedUser:
    """Resolve the authenticated caller from a verified Cognito access token.

    Raises ``HTTPException(401)`` for any of: unresolvable signing key,
    invalid/expired/mis-issued signature, ``token_use`` other than
    ``"access"``, or a ``client_id`` that doesn't match this app's Cognito
    client. Returns the resolved :class:`AuthenticatedUser` on success.
    """
    token = credentials.credentials
    settings = get_settings()

    try:
        signing_key = get_jwks_verifier().get_signing_key(token)
        payload = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            issuer=settings.cognito_issuer,
            options={"require": ["exp", "iss", "client_id", "token_use"]},
        )
    except jwt.exceptions.PyJWKClientError as exc:
        # kid can't be resolved against the JWKS -- indistinguishable from an
        # invalid token to the caller.
        raise HTTPException(status_code=401) from exc
    except jwt.exceptions.PyJWTError as exc:
        # Bad signature, expired, wrong issuer, missing required claim, etc.
        raise HTTPException(status_code=401) from exc

    # Not covered by jwt.decode's built-in validation (PyJWT has no concept
    # of client_id/token_use) -- checked manually per design.md.
    if (
        payload["token_use"] != "access"  # noqa: S105 -- Cognito claim value, not a secret
        or payload["client_id"] != settings.cognito_client_id
    ):
        raise HTTPException(status_code=401)

    return AuthenticatedUser(sub=payload["sub"], scopes=payload.get("scope", "").split())


def require_scope(scope: str) -> Callable[[AuthenticatedUser], Awaitable[AuthenticatedUser]]:
    """Build a FastAPI dependency requiring ``scope`` in the caller's scopes.

    Fully generic over ``scope`` -- this function makes no assumption about
    which scope string is passed, so it works for any endpoint's required
    scope (``api/items.read``, ``api/items.write``, or anything else) without
    special-casing any of them.

    The returned callable declares ``get_current_user`` as its own nested
    dependency (composition via ``Depends()``, not duplication), so a route
    declaring ``Depends(require_scope("some/scope"))`` gets both
    authentication (401 on an invalid/missing token, per Task 2.1) and
    authorization (403 when the token is valid but lacks ``scope``) from a
    single dependency.
    """

    async def _require_scope(
        user: Annotated[AuthenticatedUser, Depends(get_current_user)],
    ) -> AuthenticatedUser:
        if scope not in user.scopes:
            raise HTTPException(status_code=403)
        return user

    return _require_scope
