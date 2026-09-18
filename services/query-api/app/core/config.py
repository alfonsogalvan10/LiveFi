"""Typed application settings for the Query API."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    env: str = "local"
    log_level: str = "INFO"
    service_port: int = 8080

    # --- ClickHouse (OLAP) ---
    clickhouse_host: str = "clickhouse"
    clickhouse_http_port: int = 8123
    clickhouse_db: str = "livefi"
    clickhouse_user: str = "default"
    clickhouse_password: str = "change-me-clickhouse"

    # --- Redis (cache / pub-sub) ---
    redis_host: str = "redis"
    redis_port: int = 6379
    redis_db: int = 0
    redis_password: str = ""
    cache_ttl_seconds: int = 5

    # --- Auth ---
    keycloak_issuer: str = "http://keycloak:8080/realms/livefi"
    jwt_algorithm: str = "RS256"

    # --- Telemetry ---
    otel_service_name: str = "livefi-query"
    otel_exporter_otlp_endpoint: str = "http://otel-collector:4317"


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
