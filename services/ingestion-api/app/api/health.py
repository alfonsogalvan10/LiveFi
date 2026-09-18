"""Liveness and readiness probes."""

from fastapi import APIRouter, status
from fastapi.responses import JSONResponse

from app.db.session import get_pool

router = APIRouter()


@router.get("/healthz", tags=["ops"], summary="Liveness probe")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/readyz", tags=["ops"], summary="Readiness probe (checks DB)")
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
