-- ============================================================
-- LiveFi — OLAP schema (Tier 5)
-- ReplacingMergeTree gives idempotent upserts for at-least-once
-- Flink sinks; deduplication happens on merge by version.
-- ============================================================

CREATE DATABASE IF NOT EXISTS livefi;

-- ---------- Raw trade events (from Kafka CDC) ----------
CREATE TABLE IF NOT EXISTS livefi.trades_raw
(
    trade_id    UInt64,
    symbol      LowCardinality(String),
    side        LowCardinality(String),
    quantity    Decimal(20, 8),
    price       Decimal(20, 8),
    executed_at DateTime64(3, 'UTC'),
    ingested_at DateTime64(3, 'UTC') DEFAULT now64(3),
    version     UInt64 DEFAULT toUnixTimestamp64Milli(now64(3))
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(executed_at)
ORDER BY (symbol, executed_at, trade_id)
TTL toDateTime(executed_at) + INTERVAL 2 YEAR
SETTINGS index_granularity = 8192;

-- ---------- OHLC candles produced by Flink ----------
CREATE TABLE IF NOT EXISTS livefi.ohlc
(
    symbol      LowCardinality(String),
    window_start DateTime64(3, 'UTC'),
    window_end   DateTime64(3, 'UTC'),
    open        Decimal(20, 8),
    high        Decimal(20, 8),
    low         Decimal(20, 8),
    close       Decimal(20, 8),
    volume      Decimal(30, 8),
    trades      UInt64,
    version     UInt64 DEFAULT toUnixTimestamp64Milli(now64(3))
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(window_start)
ORDER BY (symbol, window_start);

-- ---------- Volume rollups ----------
CREATE TABLE IF NOT EXISTS livefi.volume_agg
(
    symbol       LowCardinality(String),
    window_start DateTime64(3, 'UTC'),
    buy_volume   Decimal(30, 8),
    sell_volume  Decimal(30, 8),
    net_volume   Decimal(30, 8),
    version      UInt64 DEFAULT toUnixTimestamp64Milli(now64(3))
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(window_start)
ORDER BY (symbol, window_start);

-- ---------- Portfolio risk snapshots ----------
CREATE TABLE IF NOT EXISTS livefi.risk_metrics
(
    portfolio_id LowCardinality(String),
    computed_at  DateTime64(3, 'UTC'),
    var_95       Decimal(20, 8),
    exposure     Decimal(20, 8),
    sharpe       Float64,
    version      UInt64 DEFAULT toUnixTimestamp64Milli(now64(3))
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(computed_at)
ORDER BY (portfolio_id, computed_at);

-- ---------- Materialized view: 1-minute candles from raw trades ----------
CREATE MATERIALIZED VIEW IF NOT EXISTS livefi.ohlc_1m_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(window_start)
ORDER BY (symbol, window_start)
AS
SELECT
    symbol,
    toStartOfMinute(executed_at) AS window_start,
    argMinState(price, executed_at) AS open,
    maxState(price)                 AS high,
    minState(price)                 AS low,
    argMaxState(price, executed_at) AS close,
    sumState(quantity)              AS volume,
    countState()                    AS trades
FROM livefi.trades_raw
GROUP BY symbol, window_start;
