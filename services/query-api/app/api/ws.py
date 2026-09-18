"""WebSocket endpoint pushing live aggregates to dashboard clients."""

import asyncio
import json
import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.core.cache import get_redis

logger = logging.getLogger(__name__)
router = APIRouter()

# Channels a client may subscribe to, mapped to Redis pub/sub channels.
ALLOWED_CHANNELS = {"analytics.ohlc", "analytics.risk", "market.prices.live"}


@router.websocket("/stream")
async def stream(websocket: WebSocket) -> None:
    """Bidirectional stream.

    Client → server: {"action": "subscribe", "channel": "analytics.ohlc"}
    Server → client: {"channel": "...", "data": {...}}
    """
    await websocket.accept()
    pubsub = get_redis().pubsub()
    subscribed: set[str] = set()

    async def pump() -> None:
        async for message in pubsub.listen():
            if message["type"] == "message":
                await websocket.send_text(
                    json.dumps({"channel": message["channel"], "data": message["data"]})
                )

    pump_task = asyncio.create_task(pump())
    try:
        while True:
            raw = await websocket.receive_text()
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                await websocket.send_json({"error": "invalid JSON"})
                continue

            channel = payload.get("channel")
            action = payload.get("action", "subscribe")

            if channel not in ALLOWED_CHANNELS:
                await websocket.send_json({"error": f"channel not permitted: {channel}"})
                continue

            if action == "subscribe" and channel not in subscribed:
                await pubsub.subscribe(channel)
                subscribed.add(channel)
                await websocket.send_json({"subscribed": channel})
            elif action == "unsubscribe" and channel in subscribed:
                await pubsub.unsubscribe(channel)
                subscribed.discard(channel)
                await websocket.send_json({"unsubscribed": channel})
    except WebSocketDisconnect:
        logger.info("websocket.client_disconnected")
    finally:
        pump_task.cancel()
        await pubsub.close()
