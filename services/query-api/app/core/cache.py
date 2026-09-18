"""Redis cache-aside helpers."""

import json
import logging
from typing import Any

import redis.asyncio as redis

from app.core.config import settings

logger = logging.getLogger(__name__)
_redis: redis.Redis | None = None


async def init_redis() -> None:
    global _redis
    _redis = redis.Redis(
        host=settings.redis_host,
        port=settings.redis_port,
        db=settings.redis_db,
        password=settings.redis_password or None,
        decode_responses=True,
    )
    await _redis.ping()
    logger.info("Redis client ready")


async def close_redis() -> None:
    global _redis
    if _redis is not None:
        await _redis.aclose()
        _redis = None


def get_redis() -> redis.Redis:
    if _redis is None:
        raise RuntimeError("Redis client is not initialised")
    return _redis


async def cached(key: str, ttl: int | None = None) -> Any | None:
    raw = await get_redis().get(key)
    return json.loads(raw) if raw else None


async def store(key: str, value: Any, ttl: int | None = None) -> None:
    await get_redis().set(
        key,
        json.dumps(value, default=str),
        ex=ttl or settings.cache_ttl_seconds,
    )


async def publish(channel: str, message: Any) -> None:
    """Fan out a live update to all WebSocket replicas."""
    await get_redis().publish(channel, json.dumps(message, default=str))
