"""Contract tests for the trade schema (no DB required)."""

from decimal import Decimal
from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.schemas.trade import TradeCreate


def test_valid_trade():
    trade = TradeCreate(
        idempotency_key=uuid4(),
        symbol="AAPL",
        side="BUY",
        quantity=Decimal("100"),
        price=Decimal("189.42"),
    )
    assert trade.side == "BUY"


def test_rejects_negative_quantity():
    with pytest.raises(ValidationError):
        TradeCreate(
            idempotency_key=uuid4(),
            symbol="AAPL",
            side="BUY",
            quantity=Decimal("-1"),
            price=Decimal("10"),
        )


def test_rejects_unknown_side():
    with pytest.raises(ValidationError):
        TradeCreate(
            idempotency_key=uuid4(),
            symbol="AAPL",
            side="HOLD",  # type: ignore[arg-type]
            quantity=Decimal("1"),
            price=Decimal("10"),
        )
