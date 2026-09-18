# LiveFi — Architecture Notes

Companion document to the top-level [`README.md`](../README.md). This file holds the deeper design rationale, data contracts, and Architecture Decision Records (ADRs).

> **New to the platform?** Read [`tiers-explained.md`](tiers-explained.md) first — it explains each tier in plain language with verification steps. This document assumes you already understand the shape of the system and covers the *why* behind specific decisions.
>
> AI agents working in this repo should load [`.pi/skills/livefi-platform/SKILL.md`](../.pi/skills/livefi-platform/SKILL.md).

---

## 1. Tier Breakdown

### Tier 1 — Client / User Layer
- **Next.js (App Router)** renders server components for the shell and client components for live charts.
- Auth uses **OAuth2 Authorization Code + PKCE** via `keycloak-js`; access tokens are held in memory (not `localStorage`) and refreshed silently.
- A single WebSocket connection multiplexes all live channels (`ohlc:AAPL`, `risk:portfolio-1`, …) using a subscribe/unsubscribe message protocol.

### Tier 2 — Edge & Security Layer
- **Kong** is the only publicly reachable backend surface.
- The **JWT plugin** validates token signatures against Keycloak's JWKS endpoint and forwards `X-Consumer-*` headers downstream.
- **Rate limiting** is applied per consumer, keyed on the JWT `sub` claim.
- Routing is path-based:
  - `POST /trades*` → `ingestion-api:8080`
  - `GET /analytics*`, `GET /ws/*` → `query-api:8080`

### Tier 3 — Ingestion & Core Operational Layer
- Pydantic models enforce the trade contract at the edge of the system (fail fast, 422 on invalid input).
- Writes are transactional and idempotent via a client-supplied `idempotency_key` unique index.
- Debezium configures a `pgoutput` publication; the replica identity is set so updates carry full row images.

### Tier 4 — Event Streaming & Processing Core
- Kafka is the **durable buffer and ordering authority**; nothing downstream is on the write critical path.
- Flink jobs use **event-time processing with watermarks** and a bounded out-of-orderness allowance, so late ticks are handled deterministically.
- Checkpointing is enabled (10s interval) with state stored in a filesystem backend locally and S3 in production.
- Two source streams (`trades` CDC and `market.prices.live`) are keyed by `symbol` and joined in a windowed interval join.

### Tier 5 — Analytics Storage & Serving Layer
- ClickHouse tables use `ReplacingMergeTree` with a version column so Flink can emit idempotent, at-least-once updates.
- Partitioning is by `toYYYYMM(timestamp)` with an `ORDER BY (symbol, timestamp)` primary key for fast time-range scans.
- Redis uses **cache-aside** with short TTLs (default 5s) plus pub/sub fan-out for WebSocket broadcast to multiple Query API replicas.

### Tier 6 — Observability
- The **OTel Collector** is the single ingest point; exporters fan out to Prometheus (metrics), Jaeger (traces), and stdout (logs).
- Trace context propagates: `traceparent` HTTP header → Kafka record headers → Flink operator.
- Alert rules cover consumer lag, p99 latency, checkpoint failures, and replication-slot lag.

---

## 2. Data Contracts

### Trade (ingestion request)

```json
{
  "idempotency_key": "3f9c1e2a-...",
  "symbol": "AAPL",
  "side": "BUY",
  "quantity": 100,
  "price": 189.42,
  "executed_at": "2024-06-01T14:32:00.123Z",
  "source": "web"
}
```

### CDC Envelope (Debezium → Kafka)

```json
{
  "op": "c",
  "before": null,
  "after": { "id": 1, "symbol": "AAPL", "quantity": 100, "price": 189.42 },
  "source": { "db": "livefi", "table": "trades", "lsn": 24023128 },
  "ts_ms": 1717252320123
}
```

---

## 3. Architecture Decision Records

| ID | Decision | Rationale |
|----|----------|-----------|
| ADR-001 | CDC (Debezium) instead of dual writes | Eliminates the dual-write inconsistency class entirely; DB remains the single source of truth. |
| ADR-002 | Kong owns port 8000; ingestion moves to 8080 | Resolves the original blueprint's port collision. Only the gateway is public. |
| ADR-003 | ClickHouse over the OLTP DB for analytics | Columnar storage + vectorized execution delivers 100–1000× faster time-range aggregations. |
| ADR-004 | Flink event-time windows | Correct results under out-of-order and late-arriving market data. |
| ADR-005 | Redis cache-aside, not write-through | Simpler invalidation; analytics freshness tolerance is a few seconds. |
| ADR-006 | Single Kafka broker locally, 3+ in prod | Keep local resource usage sane without changing application code. |
| ADR-007 | `ReplacingMergeTree` for idempotent sinks | Flink is at-least-once; versioned replaces make replays safe. |

---

## 4. Failure & Recovery

| Failure | Impact | Mitigation |
|---|---|---|
| Ingestion API down | Writes fail; reads unaffected | Horizontal replicas behind Kong upstream |
| PostgreSQL down | Writes fail | Streaming replication + failover (prod) |
| Debezium down | Events pause, WAL grows | Monitor replication-slot lag; slot retains position |
| Kafka down | Pipeline stalls | Multi-broker replication + `min.insync.replicas=2` (prod) |
| Flink job fails | Aggregates stale | Automatic restart from last checkpoint |
| ClickHouse down | Analytics unavailable | Writes buffer in Kafka; sink replays on recovery |
| Redis down | Higher latency | Query API falls through to ClickHouse |

---

## 5. Security Model


- **Authentication:** Keycloak issues RS256 JWTs; Kong validates the signature, `iss`, and `exp`.
- **Authorization:** realm roles (`viewer`, `trader`, `admin`) map to Kong consumers and service-level checks.
- **Transport:** TLS terminated at Kong (prod); mTLS optional between internal services.
- **Secrets:** injected via environment from a secrets manager; never baked into images.
- **Input validation:** Pydantic schemas at the ingestion boundary; length/range constraints on every numeric field.
