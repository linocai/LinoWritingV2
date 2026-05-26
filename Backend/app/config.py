from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", populate_by_name=True)

    database_url: str = "sqlite+pysqlite:///./lino_writing.db"
    api_token: str = Field(min_length=8)

    # v0.8 T-1 (§5.T): Key Encryption Key for ProviderKey api_key Fernet
    # encryption. A Fernet key is 32 random bytes encoded url-safe base64 →
    # exactly 44 ASCII characters (32 bytes → ceil(32/3)*4 = 44, with one
    # ``=`` pad). We assert the length plus a successful Fernet construction
    # below so any malformed value fails the process at *startup* rather than
    # surfacing as a confusing "InvalidToken" 500 on the first LLM call.
    # Generate one with:
    #     python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
    kek_secret: str = Field(min_length=44, max_length=44, validation_alias="KEK_SECRET")

    grok_api_key: str | None = None
    grok_base_url: str = "https://api.x.ai/v1"
    model_name: str = "grok-4"

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

    @field_validator("kek_secret")
    @classmethod
    def validate_fernet_kek(cls, value: str) -> str:
        """Fail-fast (process exit) when ``KEK_SECRET`` is not a valid Fernet key.

        The 44-character length check above only catches gross errors; this
        attempts the real Fernet constructor so we surface "looks like 44
        chars but base64 decoded to wrong length" and "valid base64 but not
        url-safe alphabet" both as a ValidationError at startup, before any
        request can hit ``encrypt_api_key`` and produce a less useful 500.

        Local import: ``app.services.encryption`` imports back from this
        module (via ``get_settings`` inside ``get_cipher``), so a top-level
        import here would create a circular import at module load.
        """
        from cryptography.fernet import Fernet

        try:
            Fernet(value.encode("ascii"))
        except (ValueError, TypeError) as exc:  # pragma: no cover - exact path covered by tests
            raise ValueError(
                "KEK_SECRET must be a url-safe base64-encoded 32-byte Fernet key. "
                "Generate one with: "
                "python -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\""
            ) from exc
        return value


@lru_cache
def get_settings() -> Settings:
    return Settings()
