"""Tests for Settings-related startup checks (#375)."""

from __future__ import annotations

import logging

import pytest

from api.config import Settings, warn_if_cognito_config_missing


class TestWarnIfCognitoConfigMissing:
    def test_warns_when_pool_id_and_client_id_empty(self, caplog: pytest.LogCaptureFixture) -> None:
        settings = Settings(cognito_user_pool_id="", cognito_client_id="")

        with caplog.at_level(logging.WARNING, logger="api.startup"):
            warn_if_cognito_config_missing(settings)

        record = next(r for r in caplog.records if r.name == "api.startup")
        assert "Cognito" in record.message

    def test_warns_when_only_client_id_empty(self, caplog: pytest.LogCaptureFixture) -> None:
        settings = Settings(cognito_user_pool_id="ap-northeast-1_example", cognito_client_id="")

        with caplog.at_level(logging.WARNING, logger="api.startup"):
            warn_if_cognito_config_missing(settings)

        assert any(r.name == "api.startup" for r in caplog.records)

    def test_no_warning_when_fully_configured(self, caplog: pytest.LogCaptureFixture) -> None:
        settings = Settings(
            cognito_user_pool_id="ap-northeast-1_example", cognito_client_id="client-id"
        )

        with caplog.at_level(logging.WARNING, logger="api.startup"):
            warn_if_cognito_config_missing(settings)

        assert not any(r.name == "api.startup" for r in caplog.records)
