"""The Candle contract written to PostgreSQL (and later read back as CDC)."""

from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


class Candle(BaseModel):
    """One closed OHLCV candle for a (symbol, timeframe) pair.

    Every price and volume is a Decimal, never a float. The exchange sends
    them as strings and converting through binary floats would silently lose
    precision — which matters as soon as anything sums or averages them.
    """

    model_config = ConfigDict(frozen=True)

    symbol: str
    timeframe: str
    open_time: datetime
    open: Decimal
    high: Decimal
    low: Decimal
    close: Decimal
    volume: Decimal
    trades: int
    source: str = "binance"
