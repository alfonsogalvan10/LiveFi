"""Trade persistence queries."""

from decimal import Decimal
from typing import Any
from uuid import UUID

from app.db.session import get_pool


async def insert_trade(
    *,
    idempotency_key: UUID,
    symbol: str,
    side: str,
    quantity: Decimal,
    price: Decimal,
    source: str,
) -> dict[str, Any]:
    """Insert a trade idempotently and return the persisted row.

    ON CONFLICT keeps retries safe: a duplicate submission returns the
    original row instead of creating a second trade.
    """
    query = """
        INSERT INTO trades (idempotency_key, symbol, side, quantity, price, source)
        VALUES ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (idempotency_key) DO UPDATE
            SET updated_at = now()
        RETURNING id, idempotency_key, symbol, side, quantity, price,
                  executed_at, source, created_at
    """
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            query, idempotency_key, symbol, side, quantity, price, source
        )
    return dict(row)
