"""LiveFi Ingestion API — application entrypoint.

Accepts authenticated trade submissions (via Kong) and commits them
to PostgreSQL. Debezium tails the WAL and emits CDC events to Kafka.
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator

from app.api import health, trades
from app.core.config import settings
from app.core.telemetry import setup_telemetry
from app.db.session import close_pool, init_pool


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage the DB connection pool lifecycle."""
    await init_pool()
    yield
    await close_pool()


app = FastAPI(
    title="LiveFi Ingestion API",
    description="Write path: validate and persist trades to the OLTP store.",
    version="0.1.0",
    lifespan=lifespan,
)

setup_telemetry(app, settings.otel_service_name)
Instrumentator().instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)

app.include_router(health.router)
app.include_router(trades.router, prefix="/trades", tags=["trades"])
