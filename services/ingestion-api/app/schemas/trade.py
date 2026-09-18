"""Pydantic request/response contracts for the ingestion API."""

from datetime import datetime
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class TradeCreate(BaseModel):
    """Inbound trade submission payload."""

    idempotency_key: UUID = Field(description="Client-generated key making retries safe")
    symbol: str = Field(min_length=1, max_length=16, examples=["AAPL"])
    side: Literal["BUY", "SELL"]
    quantity: Decimal = Field(gt=0, le=Decimal("1e12"), examples=["100"])
    price: Decimal = Field(gt=0, le=Decimal("1e12"), examples=["189.42"])
    source: str = Field(default="web", max_length=32)


class TradeRead(BaseModel):
    """Persisted trade representation."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    idempotency_key: UUID
    symbol: str
    side: str
    quantity: Decimal
    price: Decimal
    executed_at: datetime
    source: str
    created_at: datetime
