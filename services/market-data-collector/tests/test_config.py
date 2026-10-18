"""Settings parsing tests — the symbol list and the lookback floor are both
easy to get subtly wrong, and both fail silently in production."""

import pytest
from pydantic import ValidationError

from app.core.config import Settings


def test_symbols_are_normalised_and_deduplicated():
    settings = Settings(market_data_symbols=" btcusdt, ETHUSDT ,,btcusdt, solusdt ")
    assert settings.symbols == ["BTCUSDT", "ETHUSDT", "SOLUSDT"]


def test_lookback_below_two_is_rejected():
    # A lookback of 1 returns only the in-progress candle, so nothing would
    # ever be stored. Fail at startup instead of writing zero rows forever.
    with pytest.raises(ValidationError):
        Settings(market_data_lookback=1)


def test_default_lookback_leaves_at_least_one_closed_candle():
    assert Settings().market_data_lookback >= 2
