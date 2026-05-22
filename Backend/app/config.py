from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", populate_by_name=True)

    database_url: str = "sqlite+pysqlite:///./lino_writing.db"
    api_token: str = Field(min_length=8)

    grok_api_key: str | None = None
    grok_base_url: str = "https://api.x.ai/v1"
    model_name: str = "grok-4"
    model_name_fast: str = "grok-4-mini"

    log_level: str = "INFO"
    cors_origins: str = Field(default="*", validation_alias="CORS_ORIGINS")

    @property
    def cors_origin_list(self) -> list[str]:
        raw = self.cors_origins.strip()
        if raw == "*":
            return ["*"]
        return [item.strip() for item in raw.split(",") if item.strip()]

    @field_validator("api_token")
    @classmethod
    def reject_placeholder_token(cls, value: str) -> str:
        if value == "change-me-to-a-long-random-string":
            raise ValueError("API_TOKEN must be changed from the example placeholder")
        return value


@lru_cache
def get_settings() -> Settings:
    return Settings()
