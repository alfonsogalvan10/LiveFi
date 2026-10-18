-- ============================================================
-- LiveFi — OLTP schema bootstrap (Tier 3)
-- Runs automatically on first PostgreSQL container start.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ---------- Core trade ledger (CDC source table) ----------
CREATE TABLE IF NOT EXISTS trades (
    id              BIGSERIAL PRIMARY KEY,
    idempotency_key UUID        NOT NULL UNIQUE,
    symbol          VARCHAR(16) NOT NULL,
    side            VARCHAR(4)  NOT NULL CHECK (side IN ('BUY', 'SELL')),
    quantity        NUMERIC(20, 8) NOT NULL CHECK (quantity > 0),
    price           NUMERIC(20, 8) NOT NULL CHECK (price > 0),
    executed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    source          VARCHAR(32) NOT NULL DEFAULT 'web',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_trades_symbol_executed_at
    ON trades (symbol, executed_at DESC);
CREATE INDEX IF NOT EXISTS idx_trades_created_at
    ON trades (created_at DESC);

-- Full row image in WAL so Debezium updates carry every column
ALTER TABLE trades REPLICA IDENTITY FULL;

-- ---------- Market data candles (CDC source table) ----------
-- Written by the market-data-collector service, never by the ingestion API.
-- The collector discards the still-forming candle, so rows are insert-only and
-- their values never change. That is why this table needs no version column
-- and no REPLICA IDENTITY FULL (that only matters for UPDATE/DELETE images).
CREATE TABLE IF NOT EXISTS market_prices (
    id          BIGSERIAL PRIMARY KEY,
    symbol      VARCHAR(16)   NOT NULL,
    timeframe   VARCHAR(8)    NOT NULL DEFAULT '1m',
    open_time   TIMESTAMPTZ   NOT NULL,
    open        NUMERIC(20, 8) NOT NULL,
    high        NUMERIC(20, 8) NOT NULL,
    low         NUMERIC(20, 8) NOT NULL,
    close       NUMERIC(20, 8) NOT NULL,
    volume      NUMERIC(30, 8) NOT NULL,
    trades      INTEGER       NOT NULL,
    source      VARCHAR(32)   NOT NULL DEFAULT 'binance',
    ingested_at TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- Idempotency: re-polling a candle we already have is a no-op, so
    -- at-least-once polling cannot create duplicates.
    CONSTRAINT uq_market_prices_candle UNIQUE (symbol, timeframe, open_time)
);

CREATE INDEX IF NOT EXISTS idx_market_prices_symbol_open_time
    ON market_prices (symbol, open_time DESC);

-- ---------- CDC publication for Debezium ----------
-- Every table listed here gets a Debezium topic. New CDC source tables must
-- also be added to `table.include.list` in the connector registration script.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'livefi_publication') THEN
        CREATE PUBLICATION livefi_publication FOR TABLE trades, market_prices;
    END IF;
END $$;

-- ---------- Debezium replication role ----------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'debezium') THEN
        CREATE ROLE debezium WITH LOGIN REPLICATION PASSWORD 'change-me-debezium';
    END IF;
END $$;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO debezium;
