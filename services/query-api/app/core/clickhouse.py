"""ClickHouse client lifecycle and query helpers."""

import logging
from typing import Any

import clickhouse_connect
from clickhouse_connect.driver.client import Client

from app.core.config import settings

logger = logging.getLogger(__name__)
_client: Client | None = None


def init_client() -> None:
    global _client
    _client = clickhouse_connect.get_client(
        host=settings.clickhouse_host,
        port=settings.clickhouse_http_port,
        username=settings.clickhouse_user,
        password=settings.clickhouse_password,
        database=settings.clickhouse_db,
        compress=True,
    )
    logger.info("ClickHouse client ready")


def close_client() -> None:
    global _client
    if _client is not None:
        _client.close()
        _client = None


def get_client() -> Client:
    if _client is None:
        raise RuntimeError("ClickHouse client is not initialised")
    return _client


def query(sql: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Run a read query and return rows as dicts."""
    result = get_client().query(sql, parameters=params or {})
    return [dict(zip(result.column_names, row, strict=True)) for row in result.result_rows]
