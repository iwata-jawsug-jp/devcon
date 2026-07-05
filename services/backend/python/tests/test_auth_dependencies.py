"""Unit tests for :mod:`api.auth.dependencies` (Task 2.1).

Exercises ``get_current_user`` directly as a plain async function, passing a
manually constructed ``HTTPAuthorizationCredentials`` -- this is more direct
and just as convincing as standing up a full app route for a dependency that
takes one input and returns/raises based on token validity.

Each 401 case from the task's Definition of Done is a distinct test, plus one
positive case proving the happy path isn't accidentally broken too.
"""

from typing import Annotated, Any
from unittest.mock import patch

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPrivateKey
from fastapi import Depends, FastAPI, HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from httpx import ASGITransport, AsyncClient
from jwt.algorithms import RSAAlgorithm

from api.auth.dependencies import get_current_user, require_scope
from api.auth.jwks import get_jwks_verifier
from api.auth.schemas import AuthenticatedUser
from api.config import Settings, get_settings

KID = "test-kid-1"
ISSUER = "https://cognito-idp.ap-northeast-1.amazonaws.com/ap-northeast-1_example"
CLIENT_ID = "test-client-id"
USER_POOL_ID = "ap-northeast-1_example"
REGION = "ap-northeast-1"


def _generate_key_pair() -> RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _jwks_payload(private_key: RSAPrivateKey, kid: str) -> dict[str, Any]:
    public_jwk = RSAAlgorithm.to_jwk(private_key.public_key(), as_dict=True)
    public_jwk["kid"] = kid
    public_jwk["use"] = "sig"
    public_jwk["alg"] = "RS256"
    return {"keys": [public_jwk]}


def _sign_token(
    private_key: RSAPrivateKey,
    kid: str,
    *,
    sub: str = "user-123",
    scope: str = "api/items.read api/items.write",
    token_use: str = "access",
    client_id: str = CLIENT_ID,
    issuer: str = ISSUER,
    exp_delta_seconds: int = 3600,
) -> str:
    import time

    now = int(time.time())
    claims = {
        "sub": sub,
        "scope": scope,
        "token_use": token_use,
        "client_id": client_id,
        "iss": issuer,
        "iat": now,
        "exp": now + exp_delta_seconds,
    }
    return jwt.encode(claims, private_key, algorithm="RS256", headers={"kid": kid})


class _FakeUrlopenResponse:
    """Minimal stand-in for ``urllib.request.urlopen``'s return value.

    Mirrors the helper in ``test_jwks.py``: ``PyJWKClient.fetch_data`` does
    ``with urlopen(...) as response: json.load(response)``.
    """

    def __init__(self, payload: dict[str, Any]) -> None:
        import json

        self._body = json.dumps(payload).encode("utf-8")

    def __enter__(self) -> _FakeUrlopenResponse:
        return self

    def __exit__(self, *exc_info: object) -> None:
        return None

    def read(self) -> bytes:
        return self._body


@pytest.fixture(autouse=True)
def _settings_override() -> Any:
    """Point get_settings() at a fixed Cognito issuer/client_id for every test."""
    get_settings.cache_clear()
    get_jwks_verifier.cache_clear()

    def _get_settings_override() -> Settings:
        return Settings(
            cognito_user_pool_id=USER_POOL_ID,
            cognito_region=REGION,
            cognito_client_id=CLIENT_ID,
            cognito_issuer=ISSUER,
        )

    with (
        patch("api.auth.jwks.get_settings", _get_settings_override),
        patch("api.auth.dependencies.get_settings", _get_settings_override),
    ):
        yield
    get_settings.cache_clear()
    get_jwks_verifier.cache_clear()


def _credentials(token: str) -> HTTPAuthorizationCredentials:
    return HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)


async def _call_with_jwks(payload: dict[str, Any], token: str) -> AuthenticatedUser:
    with patch(
        "jwt.jwks_client.urllib.request.urlopen",
        return_value=_FakeUrlopenResponse(payload),
    ):
        return await get_current_user(credentials=_credentials(token))


async def test_valid_signature_and_claims_returns_authenticated_user() -> None:
    private_key = _generate_key_pair()
    payload = _jwks_payload(private_key, KID)
    token = _sign_token(private_key, KID)

    user = await _call_with_jwks(payload, token)

    assert isinstance(user, AuthenticatedUser)
    assert user.sub == "user-123"
    assert user.scopes == ["api/items.read", "api/items.write"]


async def test_tampered_signature_raises_401() -> None:
    private_key = _generate_key_pair()
    other_key = _generate_key_pair()
    # JWKS advertises private_key's public key, but the token is signed with
    # a different key entirely -- signature verification must fail.
    jwks_payload = _jwks_payload(private_key, KID)
    token = _sign_token(other_key, KID)

    with pytest.raises(HTTPException) as exc_info:
        await _call_with_jwks(jwks_payload, token)
    assert exc_info.value.status_code == 401


async def test_expired_token_raises_401() -> None:
    private_key = _generate_key_pair()
    payload = _jwks_payload(private_key, KID)
    token = _sign_token(private_key, KID, exp_delta_seconds=-3600)

    with pytest.raises(HTTPException) as exc_info:
        await _call_with_jwks(payload, token)
    assert exc_info.value.status_code == 401


async def test_token_use_other_than_access_raises_401() -> None:
    private_key = _generate_key_pair()
    payload = _jwks_payload(private_key, KID)
    token = _sign_token(private_key, KID, token_use="id")

    with pytest.raises(HTTPException) as exc_info:
        await _call_with_jwks(payload, token)
    assert exc_info.value.status_code == 401


async def test_client_id_mismatch_raises_401() -> None:
    private_key = _generate_key_pair()
    payload = _jwks_payload(private_key, KID)
    token = _sign_token(private_key, KID, client_id="some-other-client-id")

    with pytest.raises(HTTPException) as exc_info:
        await _call_with_jwks(payload, token)
    assert exc_info.value.status_code == 401


async def test_issuer_mismatch_raises_401() -> None:
    private_key = _generate_key_pair()
    payload = _jwks_payload(private_key, KID)
    token = _sign_token(private_key, KID, issuer="https://issuer.invalid/other-pool")

    with pytest.raises(HTTPException) as exc_info:
        await _call_with_jwks(payload, token)
    assert exc_info.value.status_code == 401


async def test_unresolvable_signing_key_raises_401() -> None:
    private_key = _generate_key_pair()
    # JWKS payload never advertises this kid.
    payload = _jwks_payload(private_key, "a-different-kid")
    token = _sign_token(private_key, KID)

    with pytest.raises(HTTPException) as exc_info:
        await _call_with_jwks(payload, token)
    assert exc_info.value.status_code == 401


# --- require_scope (Task 2.2) ---------------------------------------------
#
# require_scope() is called directly with an already-resolved AuthenticatedUser
# for the pure scope-comparison cases -- there's nothing token-related left to
# exercise once get_current_user (Task 2.1, tested above) has already resolved
# the user. One additional end-to-end test drives a real signed JWT through a
# throwaway FastAPI route to prove require_scope actually composes with
# get_current_user via FastAPI's Depends() nesting, rather than duplicating
# its logic.


async def test_require_scope_missing_scope_raises_403() -> None:
    user = AuthenticatedUser(sub="user-123", scopes=["api/items.read"])
    dependency = require_scope("api/items.write")

    with pytest.raises(HTTPException) as exc_info:
        await dependency(user)
    assert exc_info.value.status_code == 403


async def test_require_scope_has_scope_returns_user_unchanged() -> None:
    user = AuthenticatedUser(sub="user-123", scopes=["api/items.write"])
    dependency = require_scope("api/items.write")

    result = await dependency(user)
    assert result is user


async def test_require_scope_has_scope_among_multiple_returns_user_unchanged() -> None:
    # Realistic case: a real Cognito access token carries multiple
    # space-separated scopes (see test_valid_signature_and_claims_returns_
    # authenticated_user above). The required scope must be found via
    # membership, not by the scopes list being exactly one element -- a
    # dependency that only worked for single-scope users would silently lock
    # out every real multi-scope user in production.
    user = AuthenticatedUser(
        sub="user-123", scopes=["api/items.read", "api/items.write", "api/other.scope"]
    )
    dependency = require_scope("api/items.write")

    result = await dependency(user)
    assert result is user


async def test_require_scope_overlapping_but_not_exact_scope_raises_403() -> None:
    # Has *a* scope, just not the one required -- proves membership check,
    # not a "has any scope at all" check.
    user = AuthenticatedUser(sub="user-123", scopes=["api/items.read"])
    dependency = require_scope("api/items.write")

    with pytest.raises(HTTPException) as exc_info:
        await dependency(user)
    assert exc_info.value.status_code == 403


async def test_require_scope_is_generic_for_arbitrary_scope_strings() -> None:
    # Deliberately not an api/items.* scope -- would fail if require_scope
    # ever special-cased a specific scope name instead of staying generic.
    granted = AuthenticatedUser(sub="user-123", scopes=["custom/thing.do"])
    missing = AuthenticatedUser(sub="user-123", scopes=["some/other.scope"])
    dependency = require_scope("custom/thing.do")

    assert await dependency(granted) is granted
    with pytest.raises(HTTPException) as exc_info:
        await dependency(missing)
    assert exc_info.value.status_code == 403


async def test_require_scope_composes_with_get_current_user_via_depends() -> None:
    """End-to-end: a route depending on require_scope(...) both authenticates
    (via the nested get_current_user dependency) and authorizes from a real
    signed token, proving the composition (not a reimplementation)."""
    private_key = _generate_key_pair()
    jwks_payload = _jwks_payload(private_key, KID)
    token_with_scope = _sign_token(private_key, KID, scope="required/scope")
    token_without_scope = _sign_token(private_key, KID, scope="other/scope")

    probe_app = FastAPI()

    @probe_app.get("/probe")
    async def probe(
        user: Annotated[AuthenticatedUser, Depends(require_scope("required/scope"))],
    ) -> dict[str, str]:
        return {"sub": user.sub}

    transport = ASGITransport(app=probe_app)
    with patch(
        "jwt.jwks_client.urllib.request.urlopen",
        return_value=_FakeUrlopenResponse(jwks_payload),
    ):
        async with AsyncClient(transport=transport, base_url="http://test") as http_client:
            ok_response = await http_client.get(
                "/probe", headers={"Authorization": f"Bearer {token_with_scope}"}
            )
            forbidden_response = await http_client.get(
                "/probe", headers={"Authorization": f"Bearer {token_without_scope}"}
            )

    assert ok_response.status_code == 200
    assert ok_response.json() == {"sub": "user-123"}
    assert forbidden_response.status_code == 403
