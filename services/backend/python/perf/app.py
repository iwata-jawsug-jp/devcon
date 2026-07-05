"""ASGI entry point for load/perf testing only (Issue #43).

Serves the real `api.main.app` (same routing, Pydantic validation, and
repository/DB layer as production) but overrides `get_current_user` so
requests don't need a real Cognito-signed JWT. This is a deliberate scope
decision, not an oversight: JWT verification is a JWKS-fetch-then-decode
operation whose latency is dominated by Cognito's own service (already
covered by AWS's SLA) and by PyJWT's TTL-cached signing key, not by
anything in this app's control -- see `auth/dependencies.py`. What THIS
perf test measures is our own API's performance: FastAPI routing, Pydantic
validation, and the repository/DB layer, which is what we can actually act
on.

Not part of the `api` package (lives outside `src/`), so it is never
imported by production code and never copied into the Docker image (see
`Dockerfile`, which only `COPY`s `src`). Never point real traffic at this.
"""

from api.auth.dependencies import get_current_user
from api.auth.schemas import AuthenticatedUser
from api.main import app


def _perf_test_user() -> AuthenticatedUser:
    return AuthenticatedUser(sub="perf-test", scopes=["api/items.read", "api/items.write"])


app.dependency_overrides[get_current_user] = _perf_test_user

__all__ = ["app"]
