"""Typed application settings, loaded from the environment."""

from functools import lru_cache

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # --- Service ---
    env: str = "local"
    log_level: str = "INFO"

    # --- PostgreSQL ---
    # The collector only ever INSERTs here. Debezium reads the WAL and emits
    # the CDC events, which is why this service holds no Kafka client.
    postgres_host: str = "postgres"
    postgres_port: int = 5432
    postgres_db: str = "livefi"
    postgres_user: str = "livefi"
    postgres_password: str = "change-me-postgres"
    db_pool_min: int = 1
    db_pool_max: int = 4

    # --- Exchange feed ---
    # `data-api.binance.vision` serves public market data only, needs no API
    # key, and avoids the regional blocks that affect `api.binance.com`.
    binance_base_url: str = "https://data-api.binance.vision"
    # Comma-separated canonical symbols. Canonical == exchange symbol, so
    # there is no mapping layer to keep in sync.
    market_data_symbols: str = "BTCUSDT,ETHUSDT,SOLUSDT"
    market_data_interval: str = "1m"
    # Candles requested per poll. The final element is always the
    # still-forming candle and is discarded, so this must be >= 2 to yield
    # anything at all.
    market_data_lookback: int = 2
    market_data_poll_seconds: float = 30.0
    request_timeout_seconds: float = 10.0

    @field_validator("market_data_lookback")
    @classmethod
    def _lookback_must_leave_a_closed_candle(cls, value: int) -> int:
        if value < 2:
            raise ValueError(
                "must be >= 2: the last candle of every response is in-progress "
                "and is discarded, so a lookback of 1 stores nothing"
            )
        return value

    @property
    def dsn(self) -> str:
        return (
            f"postgresql://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    @property
    def symbols(self) -> list[str]:
        """Configured symbols, upper-cased, trimmed, de-duplicated, in order."""
        seen: list[str] = []
        for raw in self.market_data_symbols.split(","):
            symbol = raw.strip().upper()
            if symbol and symbol not in seen:
                seen.append(symbol)
        return seen


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
