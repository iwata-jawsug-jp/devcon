"""Application configuration via pydantic-settings."""

from functools import lru_cache

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


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

    @model_validator(mode="after")
    def _assemble_database_url(self) -> Settings:
        if self.db_host:
            self.database_url = (
                f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
                f"@{self.db_host}:{self.db_port}/{self.db_name}"
            )
        return self


@lru_cache
def get_settings() -> Settings:
    """Return a cached :class:`Settings` instance."""
    return Settings()
