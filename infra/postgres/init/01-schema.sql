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

-- ---------- Instrument reference data ----------
CREATE TABLE IF NOT EXISTS instruments (
    symbol      VARCHAR(16) PRIMARY KEY,
    name        VARCHAR(128) NOT NULL,
    asset_class VARCHAR(32)  NOT NULL DEFAULT 'EQUITY',
    currency    VARCHAR(3)   NOT NULL DEFAULT 'USD',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------- Portfolio risk snapshots (written by Flink) ----------
CREATE TABLE IF NOT EXISTS risk_snapshots (
    id           BIGSERIAL PRIMARY KEY,
    portfolio_id VARCHAR(64) NOT NULL,
    var_95       NUMERIC(20, 8),
    exposure     NUMERIC(20, 8),
    computed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- CDC publication for Debezium ----------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'livefi_publication') THEN
        CREATE PUBLICATION livefi_publication FOR TABLE trades, risk_snapshots;
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

-- ---------- Seed reference data ----------
INSERT INTO instruments (symbol, name, asset_class) VALUES
    ('AAPL', 'Apple Inc.',              'EQUITY'),
    ('MSFT', 'Microsoft Corporation',   'EQUITY'),
    ('GOOGL','Alphabet Inc. Class A',   'EQUITY'),
    ('TSLA', 'Tesla, Inc.',             'EQUITY'),
    ('BTC-USD', 'Bitcoin / US Dollar',  'CRYPTO')
ON CONFLICT (symbol) DO NOTHING;
