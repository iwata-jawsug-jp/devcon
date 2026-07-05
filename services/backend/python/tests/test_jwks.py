"""Unit tests for :mod:`api.auth.jwks` (Task 1.2).

Exercises the real ``PyJWKClient`` key-resolution/caching logic against a
locally generated RSA key pair and a self-served JWKS payload; only the
network fetch (``urllib.request.urlopen``, which is what ``PyJWKClient``
calls internally) is mocked.
"""

from typing import Any
from unittest.mock import patch

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPrivateKey
from jwt.algorithms import RSAAlgorithm

from api.auth.jwks import JwksVerifier, get_jwks_verifier
from api.config import Settings, get_settings

KID = "test-kid-1"


def _generate_key_pair() -> RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _jwks_payload(private_key: RSAPrivateKey, kid: str) -> dict[str, Any]:
    public_jwk = RSAAlgorithm.to_jwk(private_key.public_key(), as_dict=True)
    public_jwk["kid"] = kid
    public_jwk["use"] = "sig"
    public_jwk["alg"] = "RS256"
    return {"keys": [public_jwk]}


def _sign_token(private_key: RSAPrivateKey, kid: str) -> str:
    return jwt.encode(
        {"sub": "user-123"},
        private_key,
        algorithm="RS256",
        headers={"kid": kid},
    )


class _FakeUrlopenResponse:
    """Minimal stand-in for the object returned by ``urllib.request.urlopen``.

    ``PyJWKClient.fetch_data`` does ``with urlopen(...) as response:
    json.load(response)``, so this only needs context-manager support plus
    ``read()`` (``json.load`` calls ``fp.read()``).
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


def test_get_signing_key_returns_matching_public_key() -> None:
    private_key = _generate_key_pair()
    payload = _jwks_payload(private_key, KID)
    token = _sign_token(private_key, KID)

    verifier = JwksVerifier(jwks_uri="https://example.invalid/.well-known/jwks.json")

    with patch(
        "jwt.jwks_client.urllib.request.urlopen",
        return_value=_FakeUrlopenResponse(payload),
    ) as mock_urlopen:
        signing_key = verifier.get_signing_key(token)

    assert mock_urlopen.called
    expected_public_numbers = private_key.public_key().public_numbers()
    actual_public_numbers = signing_key.key.public_numbers()
    assert actual_public_numbers.n == expected_public_numbers.n
    assert actual_public_numbers.e == expected_public_numbers.e
    assert signing_key.key_id == KID


def test_get_signing_key_unknown_kid_raises_pyjwk_client_error() -> None:
    private_key = _generate_key_pair()
    payload = _jwks_payload(private_key, KID)
    # Token references a kid that is absent from the served JWKS payload.
    token = _sign_token(private_key, "some-other-kid")

    verifier = JwksVerifier(jwks_uri="https://example.invalid/.well-known/jwks.json")

    with (
        patch(
            "jwt.jwks_client.urllib.request.urlopen",
            return_value=_FakeUrlopenResponse(payload),
        ),
        pytest.raises(jwt.exceptions.PyJWKClientError),
    ):
        verifier.get_signing_key(token)


def test_settings_derive_cognito_issuer_from_pool_id_and_region() -> None:
    settings = Settings(
        cognito_user_pool_id="ap-northeast-1_example",
        cognito_region="ap-northeast-1",
    )
    assert (
        settings.cognito_issuer
        == "https://cognito-idp.ap-northeast-1.amazonaws.com/ap-northeast-1_example"
    )


def test_settings_respects_explicit_cognito_issuer_override() -> None:
    settings = Settings(
        cognito_user_pool_id="ap-northeast-1_example",
        cognito_region="ap-northeast-1",
        cognito_issuer="https://issuer.example.invalid",
    )
    assert settings.cognito_issuer == "https://issuer.example.invalid"


def test_get_jwks_verifier_returns_cached_singleton_built_from_settings() -> None:
    get_settings.cache_clear()
    get_jwks_verifier.cache_clear()
    try:
        verifier_a = get_jwks_verifier()
        verifier_b = get_jwks_verifier()
        assert verifier_a is verifier_b
        assert isinstance(verifier_a, JwksVerifier)
    finally:
        get_settings.cache_clear()
        get_jwks_verifier.cache_clear()
