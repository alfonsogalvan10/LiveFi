"""LiveFi Query API — read-optimized serving layer.

Serves aggregated analytics from ClickHouse with a Redis cache-aside
front, and pushes live updates over WebSocket.
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator

from app.api import analytics, health, ws
from app.core.cache import close_redis, init_redis
from app.core.clickhouse import close_client, init_client
from app.core.config import settings
from app.core.telemetry import setup_telemetry


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_client()
    await init_redis()
    yield
    await close_redis()
    close_client()


app = FastAPI(
    title="LiveFi Query API",
    description="Read path: cached OLAP analytics for the dashboard.",
    version="0.1.0",
    lifespan=lifespan,
)

setup_telemetry(app, settings.otel_service_name)
Instrumentator().instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)

app.include_router(health.router)
app.include_router(analytics.router, prefix="/analytics", tags=["analytics"])
app.include_router(ws.router, prefix="/ws", tags=["streaming"])
