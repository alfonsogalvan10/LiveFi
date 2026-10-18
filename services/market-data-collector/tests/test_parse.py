"""Kline parsing tests.

The positional index map in `app/binance/parse.py` is the riskiest part of this
service: every element is a number or a numeric string, so a wrong index still
parses cleanly and simply stores the wrong value in the wrong column. These
tests pin the mapping and the in-progress-candle rule.
"""

from datetime import UTC, datetime, timedelta
from decimal import Decimal

from app.binance.parse import closed_candles

SYMBOL = "BTCUSDT"
TIMEFRAME = "1m"
BASE_MS = 1_700_000_000_000  # 2023-11-14T22:13:20Z


def make_kline(
    open_time_ms: int = BASE_MS,
    open_: str = "100.5",
    high: str = "110.25",
    low: str = "99.75",
    close: str = "105.0",
    volume: str = "12.5",
    trades: int = 7,
) -> list:
    """A full 12-element kline array, in the order the exchange sends it."""
    return [
        open_time_ms,          # 0  open time
        open_,                 # 1  open
        high,                  # 2  high
        low,                   # 3  low
        close,                 # 4  close
        volume,                # 5  volume
        open_time_ms + 59_999,  # 6  close time (ignored)
        "1234.5",              # 7  quote volume (ignored)
        trades,                # 8  trade count
        "6.25",                # 9  taker buy base volume (ignored)
        "650.0",               # 10 taker buy quote volume (ignored)
        "0",                   # 11 unused
    ]


def test_maps_each_position_to_the_right_column():
    candles = closed_candles(
        SYMBOL, TIMEFRAME, [make_kline(), make_kline(open_time_ms=BASE_MS + 60_000)]
    )
    candle = candles[0]

    assert candle.symbol == SYMBOL
    assert candle.timeframe == TIMEFRAME
    assert candle.open == Decimal("100.5")
    assert candle.high == Decimal("110.25")
    assert candle.low == Decimal("99.75")
    assert candle.close == Decimal("105.0")
    assert candle.volume == Decimal("12.5")
    assert candle.trades == 7


def test_prices_and_volume_stay_decimal():
    candles = closed_candles(SYMBOL, TIMEFRAME, [make_kline(), make_kline()])

    assert isinstance(candles[0].open, Decimal)
    assert isinstance(candles[0].close, Decimal)
    assert isinstance(candles[0].volume, Decimal)


def test_open_time_is_exact_utc():
    candles = closed_candles(SYMBOL, TIMEFRAME, [make_kline(), make_kline()])

    assert candles[0].open_time == datetime(2023, 11, 14, 22, 13, 20, tzinfo=UTC)
    assert candles[0].open_time.utcoffset() == timedelta(0)


def test_discards_the_still_forming_candle():
    candles = closed_candles(
        SYMBOL,
        TIMEFRAME,
        [
            make_kline(BASE_MS),
            make_kline(BASE_MS + 60_000),
            make_kline(BASE_MS + 120_000),  # in-progress — must not be stored
        ],
    )

    assert len(candles) == 2
    assert [int(c.open_time.timestamp() * 1000) for c in candles] == [BASE_MS, BASE_MS + 60_000]


def test_response_containing_only_an_open_candle_stores_nothing():
    assert closed_candles(SYMBOL, TIMEFRAME, [make_kline()]) == []


def test_empty_response_stores_nothing():
    assert closed_candles(SYMBOL, TIMEFRAME, []) == []
