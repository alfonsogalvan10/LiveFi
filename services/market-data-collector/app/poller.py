"""The poll loop: exchange REST -> PostgreSQL insert.

This is the whole of the collector's behaviour. Failures are logged and
retried on the next tick rather than propagated, because pipeline correctness
does not depend on the collector being continuously up — Debezium reads the
WAL, so anything written is delivered regardless.
"""

import asyncio
import logging

import httpx

from app.binance import client as binance
from app.binance.parse import closed_candles
from app.core.config import settings
from app.db import prices_repo

logger = logging.getLogger(__name__)


async def poll_once(http_client: httpx.AsyncClient) -> int:
    """Fetch and store one round of candles for every configured symbol.

    Returns the number of rows actually inserted (duplicates count as zero).
    """
    written = 0
    for symbol in settings.symbols:
        klines = await binance.fetch_klines(http_client, symbol, settings.market_data_lookback)
        candles = closed_candles(symbol, settings.market_data_interval, klines)
        written += await prices_repo.insert_candles(candles)
    return written


async def run(stop: asyncio.Event) -> None:
    """Poll until `stop` is set. Never raises on upstream failure."""
    # Values are interpolated into the message rather than passed via `extra=`.
    # `extra` needs a logging format that names the field, and the default
    # format used here does not — so the numbers would be silently dropped,
    # which is exactly when you most need them.
    logger.info(
        "market_data.polling_started symbols=%s timeframe=%s poll_seconds=%s source=%s",
        settings.symbols,
        settings.market_data_interval,
        settings.market_data_poll_seconds,
        settings.binance_base_url,
    )
    async with binance.build_client() as http_client:
        while not stop.is_set():
            try:
                written = await poll_once(http_client)
                logger.info("market_data.poll_complete rows_inserted=%d", written)
            except Exception:  # noqa: BLE001 — one bad poll must not kill the loop
                logger.warning("market_data.poll_failed", exc_info=True)

            # Wait on the event rather than sleeping, so shutdown is immediate
            # instead of blocking for the rest of the interval.
            try:
                await asyncio.wait_for(stop.wait(), timeout=settings.market_data_poll_seconds)
            except TimeoutError:
                pass
    logger.info("market_data.polling_stopped")
