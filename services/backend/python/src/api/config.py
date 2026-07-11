"""Application configuration via pydantic-settings."""

import logging
from functools import lru_cache

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

logger = logging.getLogger("api.startup")


class Settings(BaseSettings):
    """Runtime settings, overridable via ``API_*`` env vars or ``.env``."""

    model_config = SettingsConfigDict(env_prefix="API_", env_file=".env", extra="ignore")

    app_name: str = "api"
    environment: str = "dev"
    database_url: str = "postgresql+asyncpg://app:app@localhost:5432/app"

    # Component-based DB config. When ``db_host`` is set (e.g. injected by ECS from
    # the RDS outputs + the RDS-managed master secret), ``database_url`` is assembled
    # from these instead of being provided whole. Keeps the single source of truth in
    # ``database_url`` while letting the deploy supply pieces (password via a secret).
    db_host: str = ""
    db_port: int = 5432
    db_name: str = "app"
    db_user: str = "app"
    db_password: str = ""

    # Cognito authn/authz settings (non-secret; the public client has no client
    # secret — see infra/auth.tf's ``generate_secret = false``). ``cognito_issuer``
    # is derived from the pool ID + region unless explicitly overridden, matching
    # Cognito's own issuer claim format.
    cognito_user_pool_id: str = ""
    cognito_region: str = "ap-northeast-1"
    cognito_client_id: str = ""
    cognito_issuer: str = ""

    # Distributed tracing (OpenTelemetry -> ADOT collector sidecar -> AWS X-Ray,
    # ADR-0007). Off by default (e.g. local dev has no collector to send to);
    # the ECS task definition enables it in prod via API_OTEL_TRACES_ENABLED=true.
    # The collector sidecar shares the task's network namespace (awsvpc), so
    # "localhost" is correct even though it's a separate container.
    otel_traces_enabled: bool = False
    otel_exporter_endpoint: str = "http://localhost:4317"
    otel_service_name: str = "api"

    @model_validator(mode="after")
    def _assemble_database_url(self) -> Settings:
        if self.db_host:
            self.database_url = (
                f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
                f"@{self.db_host}:{self.db_port}/{self.db_name}"
            )
        return self

    @model_validator(mode="after")
    def _assemble_cognito_issuer(self) -> Settings:
        if not self.cognito_issuer and self.cognito_user_pool_id:
            self.cognito_issuer = (
                f"https://cognito-idp.{self.cognito_region}.amazonaws.com/"
                f"{self.cognito_user_pool_id}"
            )
        return self


def warn_if_cognito_config_missing(settings: Settings) -> None:
    """Warn (don't block startup) if Cognito isn't configured (#375).

    An empty pool id / client id doesn't break startup or ``/api/health`` --
    the app comes up looking healthy while nobody can actually log in (#367,
    #369). Surface it in the startup logs so a missing-config deploy is
    visible without waiting for a user to hit the auth flow.
    """
    if not settings.cognito_user_pool_id or not settings.cognito_client_id:
        logger.warning(
            "Cognito is not configured (cognito_user_pool_id/cognito_client_id "
            "empty) -- authentication will not work"
        )


@lru_cache
def get_settings() -> Settings:
    """Return a cached :class:`Settings` instance."""
    return Settings()
