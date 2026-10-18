"""HTTP client for the exchange's public market-data API."""

import logging
from typing import Any

import httpx

from app.core.config import settings

logger = logging.getLogger(__name__)


def build_client() -> httpx.AsyncClient:
    """Create a client with a fixed base URL and bounded timeout.

    The timeout is mandatory: without one, a stalled upstream hangs the poll
    loop for as long as the socket stays open.
    """
    return httpx.AsyncClient(
        base_url=settings.binance_base_url,
        timeout=httpx.Timeout(settings.request_timeout_seconds),
    )


async def fetch_klines(client: httpx.AsyncClient, symbol: str, limit: int) -> list[list[Any]]:
    """Fetch the most recent klines for one symbol.

    Returns an empty list on any transport or HTTP error instead of raising,
    so one rejected symbol cannot prevent the others from being polled. The
    failure is logged and retried on the next tick.
    """
    try:
        response = await client.get(
            "/api/v3/klines",
            params={
                "symbol": symbol,
                "interval": settings.market_data_interval,
                "limit": limit,
            },
        )
        response.raise_for_status()
        return response.json()
    except httpx.HTTPError as exc:
        logger.warning("market_data.fetch_failed symbol=%s error=%s", symbol, exc)
        return []
    except ValueError as exc:
        # Malformed JSON — treat it like any other upstream failure.
        logger.warning("market_data.malformed_response symbol=%s error=%s", symbol, exc)
        return []
