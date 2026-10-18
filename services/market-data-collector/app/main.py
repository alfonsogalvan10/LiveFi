"""LiveFi Market Data Collector — application entrypoint.

Polls a public exchange REST API and INSERTs closed candles into PostgreSQL.
Debezium reads the WAL and emits the CDC events downstream; this service
holds no Kafka client on purpose (see the design rules).
"""

import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api import health
from app.core.config import settings
from app.db.session import close_pool, init_pool
from app.poller import run

logging.basicConfig(
    level=settings.log_level.upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Run the poll loop for the lifetime of the process, then stop it cleanly."""
    await init_pool()
    stop = asyncio.Event()
    poller = asyncio.create_task(run(stop))
    try:
        yield
    finally:
        stop.set()
        await poller
        await close_pool()


app = FastAPI(
    title="LiveFi Market Data Collector",
    description="Polls a public exchange API and persists candles to the OLTP store.",
    version="0.1.0",
    lifespan=lifespan,
)

app.include_router(health.router)
