"""Translate exchange kline payloads into Candle objects.

The exchange returns each kline as a POSITIONAL array with no field names, so
the indices below are the entire contract:

    https://developers.binance.com/docs/binance-spot-api-docs/rest-api/market-data-endpoints

Getting an index wrong is silent — every element is either a number or a
numeric string — which is why the mapping is asserted in tests/test_parse.py.
"""

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any

from app.schemas.candle import Candle

# Index -> field for the fields we store. Elements 6, 7, 9, 10 and 11
# (close time, quote volume, taker-buy volumes, unused) are ignored.
OPEN_TIME = 0
OPEN = 1
HIGH = 2
LOW = 3
CLOSE = 4
VOLUME = 5
TRADE_COUNT = 8

# open_time arrives as Unix milliseconds. Adding a timedelta to the epoch is
# exact; float-dividing by 1000 is not guaranteed to be.
_EPOCH = datetime(1970, 1, 1, tzinfo=UTC)


def candle_from_kline(symbol: str, timeframe: str, kline: list[Any]) -> Candle:
    """Convert one kline array into a Candle."""
    return Candle(
        symbol=symbol,
        timeframe=timeframe,
        open_time=_EPOCH + timedelta(milliseconds=int(kline[OPEN_TIME])),
        open=Decimal(kline[OPEN]),
        high=Decimal(kline[HIGH]),
        low=Decimal(kline[LOW]),
        close=Decimal(kline[CLOSE]),
        volume=Decimal(kline[VOLUME]),
        trades=int(kline[TRADE_COUNT]),
    )


def closed_candles(symbol: str, timeframe: str, klines: list[list[Any]]) -> list[Candle]:
    """Convert a kline response, discarding the still-forming candle.

    The exchange always returns the candle covering *now* as the final
    element, and its high/low/close/volume are still changing. Persisting it
    would freeze a partial value permanently, because inserts are
    ON CONFLICT DO NOTHING and would never correct it.

    Dropping it costs at most one interval of latency and keeps the write path
    strictly insert-only, which is what removes the need for a version column.
    """
    if len(klines) < 2:
        # Everything in the response is in-progress — nothing safe to store.
        return []
    return [candle_from_kline(symbol, timeframe, kline) for kline in klines[:-1]]
