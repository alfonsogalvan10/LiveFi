"""Liveness and readiness probes for the Query API."""

from fastapi import APIRouter, status
from fastapi.responses import JSONResponse

from app.core.cache import get_redis
from app.core.clickhouse import get_client

router = APIRouter()


@router.get("/healthz", tags=["ops"], summary="Liveness probe")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/readyz", tags=["ops"], summary="Readiness probe (ClickHouse + Redis)")
async def readyz() -> JSONResponse:
    checks: dict[str, str] = {}
    try:
        get_client().query("SELECT 1")
        checks["clickhouse"] = "ok"
    except Exception:  # noqa: BLE001
        checks["clickhouse"] = "unreachable"
    try:
        await get_redis().ping()
        checks["redis"] = "ok"
    except Exception:  # noqa: BLE001
        checks["redis"] = "unreachable"

    ready = all(v == "ok" for v in checks.values())
    return JSONResponse(
        status_code=status.HTTP_200_OK if ready else status.HTTP_503_SERVICE_UNAVAILABLE,
        content={"status": "ready" if ready else "degraded", **checks},
    )
