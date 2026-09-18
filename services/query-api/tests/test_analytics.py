"""Sanity tests for query response models."""

from datetime import UTC, datetime

from app.schemas.analytics import Candle


def test_candle_model_parses():
    candle = Candle(
        window_start=datetime.now(UTC),
        open=1.0,
        high=2.0,
        low=0.5,
        close=1.5,
        volume=1000.0,
    )
    assert candle.high >= candle.low
