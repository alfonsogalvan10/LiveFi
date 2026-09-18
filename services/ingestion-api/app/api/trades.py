"""Trade ingestion endpoints."""

import logging

from fastapi import APIRouter, HTTPException, status

from app.db import trades_repo
from app.schemas.trade import TradeCreate, TradeRead

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post(
    "",
    response_model=TradeRead,
    status_code=status.HTTP_201_CREATED,
    summary="Submit a trade",
)
async def create_trade(payload: TradeCreate) -> TradeRead:
    """Validate and persist a trade.

    Kong has already authenticated the caller before this handler runs.
    Persistence triggers Debezium CDC → Kafka → Flink downstream.
    """
    try:
        row = await trades_repo.insert_trade(**payload.model_dump())
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to persist trade")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Unable to persist trade",
        ) from exc

    logger.info("trade.persisted", extra={"trade_id": row["id"], "symbol": row["symbol"]})
    return TradeRead.model_validate(row)
