"""Application configuration via pydantic-settings."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime settings, overridable via ``API_*`` env vars or ``.env``."""

    model_config = SettingsConfigDict(env_prefix="API_", env_file=".env", extra="ignore")

    app_name: str = "api"
    environment: str = "dev"


@lru_cache
def get_settings() -> Settings:
    """Return a cached :class:`Settings` instance."""
    return Settings()
