"""Sanity tests for query parameter validation."""

from app.schemas.analytics import Candle
from datetime import datetime, timezone


def test_candle_model_parses():
    candle = Candle(
        window_start=datetime.now(timezone.utc),
        open=1.0,
        high=2.0,
        low=0.5,
        close=1.5,
        volume=1000.0,
    )
    assert candle.high >= candle.low
