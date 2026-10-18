"""Liveness and readiness probes.

The collector has no HTTP ingress: it is a background poller, so these exist
only so Compose and `make ps` can report whether it is alive and has a usable
database connection.
"""

from fastapi import APIRouter, status
from fastapi.responses import JSONResponse

from app.core.config import settings
from app.db.session import get_pool

router = APIRouter()


@router.get("/healthz", tags=["ops"], summary="Liveness probe")
async def healthz() -> dict[str, object]:
    return {
        "status": "ok",
        "symbols": settings.symbols,
        "timeframe": settings.market_data_interval,
        "poll_seconds": settings.market_data_poll_seconds,
    }


@router.get("/readyz", tags=["ops"], summary="Readiness probe (checks the DB)")
async def readyz() -> JSONResponse:
    try:
        async with get_pool().acquire() as conn:
            await conn.fetchval("SELECT 1")
    except Exception:  # noqa: BLE001
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"status": "degraded", "database": "unreachable"},
        )
    return JSONResponse(status_code=status.HTTP_200_OK, content={"status": "ready"})
