"""Typed application settings, loaded from the environment."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # --- Service ---
    env: str = "local"
    log_level: str = "INFO"
    service_port: int = 8080

    # --- PostgreSQL ---
    postgres_host: str = "postgres"
    postgres_port: int = 5432
    postgres_db: str = "livefi"
    postgres_user: str = "livefi"
    postgres_password: str = "change-me-postgres"
    db_pool_min: int = 2
    db_pool_max: int = 10

    # --- Auth ---
    keycloak_issuer: str = "http://keycloak:8080/realms/livefi"
    jwt_algorithm: str = "RS256"

    # --- Telemetry ---
    otel_service_name: str = "livefi-ingestion"
    otel_exporter_otlp_endpoint: str = "http://otel-collector:4317"

    @property
    def dsn(self) -> str:
        return (
            f"postgresql://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
