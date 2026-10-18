"""Persistence for market_prices rows.

This is the only write path into the table. Each inserted row becomes a CDC
event via Debezium reading the WAL — this service never publishes to Kafka.
"""

from app.db.session import get_pool
from app.schemas.candle import Candle

# DO NOTHING makes the write idempotent: re-polling a candle we already stored
# is a no-op rather than a duplicate. That is what makes at-least-once polling
# safe, and it is the reason the table needs no version column — the collector
# only ever inserts, never updates.
_INSERT = """
    INSERT INTO market_prices
        (symbol, timeframe, open_time, open, high, low, close, volume, trades, source)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
    ON CONFLICT (symbol, timeframe, open_time) DO NOTHING
    RETURNING id
"""


async def insert_candles(candles: list[Candle]) -> int:
    """Insert candles, skipping any already stored.

    Returns the number of rows actually written, so the caller can tell a
    productive poll from one where every candle was a duplicate.
    """
    written = 0
    async with get_pool().acquire() as conn:
        for candle in candles:
            row = await conn.fetchrow(
                _INSERT,
                candle.symbol,
                candle.timeframe,
                candle.open_time,
                candle.open,
                candle.high,
                candle.low,
                candle.close,
                candle.volume,
                candle.trades,
                candle.source,
            )
            if row is not None:
                written += 1
    return written
