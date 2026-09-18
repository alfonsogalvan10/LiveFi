"""Response schemas for the Query API."""

from datetime import datetime

from pydantic import BaseModel


class Candle(BaseModel):
    window_start: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float


class OhlcResponse(BaseModel):
    cached: bool
    symbol: str
    candles: list[Candle]


class RiskMetrics(BaseModel):
    computed_at: datetime
    var_95: float | None = None
    exposure: float | None = None
    sharpe: float | None = None
