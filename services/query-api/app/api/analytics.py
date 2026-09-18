"""Analytics read endpoints (ClickHouse + Redis cache-aside)."""

import logging
from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, Query

from app.core import clickhouse
from app.core.cache import cached, store

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/ohlc", summary="OHLC candles for a symbol")
async def get_ohlc(
    symbol: str = Query(..., min_length=1, max_length=16),
    minutes: int = Query(60, ge=1, le=1440),
    interval: str = Query("1m", pattern="^(1s|1m|5m|1h)$"),
) -> dict:
    """Return OHLC candles, served from cache when warm."""
    key = f"ohlc:{symbol}:{interval}:{minutes}"
    if (hit := await cached(key)) is not None:
        return {"cached": True, "symbol": symbol, "candles": hit}

    since = datetime.now(UTC) - timedelta(minutes=minutes)
    rows = clickhouse.query(
        """
        SELECT window_start,
               argMin(open,  window_start) AS open,
               max(high)   AS high,
               min(low)    AS low,
               argMax(close, window_start) AS close,
               sum(volume) AS volume
        FROM livefi.ohlc
        WHERE symbol = {symbol:String}
          AND window_start >= {since:DateTime64(3)}
        GROUP BY window_start
        ORDER BY window_start
        """,
        {"symbol": symbol, "since": since},
    )
    await store(key, rows)
    return {"cached": False, "symbol": symbol, "candles": rows}


@router.get("/volume", summary="Aggregated buy/sell volume")
async def get_volume(
    symbol: str = Query(..., min_length=1, max_length=16),
    minutes: int = Query(60, ge=1, le=1440),
) -> dict:
    key = f"volume:{symbol}:{minutes}"
    if (hit := await cached(key)) is not None:
        return {"cached": True, "symbol": symbol, "buckets": hit}

    since = datetime.now(UTC) - timedelta(minutes=minutes)
    rows = clickhouse.query(
        """
        SELECT window_start, buy_volume, sell_volume, net_volume
        FROM livefi.volume_agg
        WHERE symbol = {symbol:String}
          AND window_start >= {since:DateTime64(3)}
        ORDER BY window_start
        """,
        {"symbol": symbol, "since": since},
    )
    await store(key, rows)
    return {"cached": False, "symbol": symbol, "buckets": rows}


@router.get("/risk", summary="Latest portfolio risk metrics")
async def get_risk(portfolio_id: str = Query(..., min_length=1, max_length=64)) -> dict:
    key = f"risk:{portfolio_id}"
    if (hit := await cached(key)) is not None:
        return {"cached": True, "portfolio_id": portfolio_id, "metrics": hit}

    rows = clickhouse.query(
        """
        SELECT computed_at, var_95, exposure, sharpe
        FROM livefi.risk_metrics
        WHERE portfolio_id = {pid:String}
        ORDER BY computed_at DESC
        LIMIT 1
        """,
        {"pid": portfolio_id},
    )
    metrics = rows[0] if rows else None
    await store(key, metrics)
    return {"cached": False, "portfolio_id": portfolio_id, "metrics": metrics}
