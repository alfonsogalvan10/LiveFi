# The Six Tiers, Explained

A guided tour of every layer in the LiveFi platform: what it does, why it exists, which files configure it, and how to tell whether it's working.

**Who this is for:** anyone new to the project, new to distributed systems, or returning after time away. No prior knowledge of Kafka, Flink, or CDC is assumed.

**How to read it:** the tiers are ordered by data flow, top to bottom. Each tier builds on the ideas in the previous one. If a term is unfamiliar, check [Core Concepts](#core-concepts) first.

---

## Table of Contents

- [Core Concepts](#core-concepts)
- [Tier 1 — Client](#tier-1--client-the-frontend)
- [Tier 2 — Edge & Security](#tier-2--edge--security-the-front-door)
- [Tier 3 — Ingestion & Operational](#tier-3--ingestion--operational-the-record-keeper)
- [Tier 4 — Stream Processing](#tier-4--stream-processing-the-factory)
- [Tier 5 — Analytics & Serving](#tier-5--analytics--serving-the-library)
- [Tier 6 — Observability](#tier-6--observability-the-control-room)
- [A Trade's Full Journey](#a-trades-full-journey)
- [Gotchas](#gotchas)

---

## Core Concepts

Five ideas underpin the whole design. Everything else is a consequence of these.

### OLTP vs OLAP

Two fundamentally different ways to use data, requiring different databases.

| | OLTP | OLAP |
|---|---|---|
| Stands for | Online **Transaction** Processing | Online **Analytical** Processing |
| Workload | Many small, fast operations | Fewer, huge scan-heavy operations |
| Example query | "Record this trade" | "Average price per day for 30 days" |
| Optimized for | Instant single-row reads/writes | Aggregating billions of rows |
| In LiveFi | **PostgreSQL** | **ClickHouse** |

**Analogy:** OLTP is a cash register — fast, one transaction at a time. OLAP is the accountant at year-end going through every receipt — slow per query, but sees everything at once. You don't ask the cashier to do your taxes.

**Why it matters:** a row-based database optimized for fast inserts is *bad* at scanning 30 days of history, and running such a query on it will slow down concurrent writes. Splitting the two workloads onto two engines means analytics can never degrade the write path.

### Event Streaming

Instead of services calling each other directly, they communicate through a **durable, ordered log of events**.

**Kafka** is that log. Think of it as a group chat where every message is permanently retained. Producers post messages; consumers read the ones they care about. Messages are organized into named channels called **topics**.

**Why this beats direct calls:**
- **Decoupling** — if a consumer is down, messages wait. Nothing is lost.
- **Extensibility** — a new service can start reading an existing topic with zero changes elsewhere.
- **Isolation** — one consumer crashing cannot cascade into another.
- **Replay** — a bug can be fixed and the stream reprocessed from an earlier offset.

### CDC (Change Data Capture)

The naive way to get data into Kafka: the application writes to the database **and** publishes to Kafka. Two writes.

**The dual-write problem:** if the process crashes *between* those two writes, the database has the record and Kafka does not. They permanently disagree, and there is no reliable way to detect or repair it.

**CDC eliminates this.** Every database maintains a **write-ahead log (WAL)** — a private journal written *before* changes are applied, used for crash recovery. CDC reads that journal and converts entries into events automatically. **Debezium** implements this.

So the ingestion service writes to PostgreSQL **only**. Debezium derives the events from the same transaction that changed the database. They cannot diverge.

**Analogy:** instead of a bank teller updating two ledgers by hand (and possibly forgetting one), you keep one ledger and attach a photocopier that copies every new page. The copier can't fall out of sync because it copies what was actually written.

### JWT (JSON Web Token)

A JWT is a cryptographically **signed** token containing claims — typically who the user is and what roles they hold. The signature lets any service verify authenticity **without contacting the issuer**, which is what makes it scale.

Format: `header.payload.signature`, base64url-encoded and dot-separated. The payload is readable by anyone — it is signed, not encrypted. Never put secrets in it.

In LiveFi: Keycloak signs JWTs; Kong verifies them using Keycloak's public key; internal services trust that Kong already checked.

### WebSocket

A normal HTTP request is one-shot: ask, receive, connection closes. To show live data you would have to ask again repeatedly ("polling"), which wastes requests and adds latency.

A **WebSocket** upgrades the connection to a persistent, two-way channel. The server can **push** updates the moment they happen. LiveFi uses one WebSocket per browser tab, multiplexed across multiple data channels via a subscribe/unsubscribe message protocol.

---

## Tier 1 — Client (the Frontend)

> What the human sees and interacts with.

**Technology:** Next.js, React, Tailwind CSS, TradingView Lightweight Charts
**Files:** `frontend/`

### What it does

1. **Authenticates** the user against Keycloak (OAuth2 Authorization Code + PKCE).
2. **Fetches history** over HTTPS — e.g. the last 120 minutes of candles.
3. **Streams live updates** over a single WebSocket.

### Why these choices

- **React** builds UI from composable components. **Next.js** adds routing, server-side rendering, and bundling on top.
- **TradingView Lightweight Charts** is a canvas-based financial charting library; a generic charting lib would be slower with large candle series and wouldn't render candlesticks idiomatically.
- **Tailwind** puts styling next to markup, avoiding separate CSS files.

### Key files

| Path | Purpose |
|---|---|
| `app/layout.tsx` | Root shell: HTML structure, global header, metadata |
| `app/page.tsx` | Dashboard page; wires data fetching + live stream together |
| `components/PriceChart.tsx` | TradingView candlestick chart wrapper |
| `lib/api.ts` | HTTP client; attaches the bearer token to every request |
| `lib/useLiveStream.ts` | WebSocket hook with auto-reconnect and exponential backoff |

### How to verify it works

```bash
cd frontend && pnpm dev
# open http://localhost:3000 — a chart and a "live"/"offline" badge should render
```

### Common failure

Charts render but stay empty → the Query API returned no rows. Most likely cause: ClickHouse has no data yet (see [Gotchas](#gotchas)).

---

## Tier 2 — Edge & Security (the Front Door)

> A single, hardened entry point. No service is reachable without passing through it.

**Technology:** Kong Gateway, Keycloak
**Files:** `infra/kong/kong.yml`, `infra/keycloak/realm-export.json`

### What it does

**Kong** is an **API Gateway** — a reverse proxy that sits in front of all backend services. Every request hits Kong first, and Kong:

- Verifies the JWT signature against Keycloak's public key
- Enforces rate limits per consumer
- Applies CORS policy
- Routes by URL path to the correct internal service
- Emits metrics for everything it sees

**Keycloak** is an **Identity Provider (IAM)**. It owns users, credentials, and roles, and issues signed JWTs. It speaks OAuth2 and OpenID Connect.

### Why this exists

Without a gateway, *every* backend service must implement authentication, rate limiting, and CORS. That is duplicated code and duplicated bugs. Centralizing it means:

- Services stay simple — they assume the caller is already authenticated.
- Security policy changes happen in one file, not ten.
- Internal services are never exposed to the internet.

### Routing table

| Path | Target | Auth |
|---|---|---|
| `POST /trades` | `ingestion-api:8080` | Required (JWT + rate limit) |
| `GET /analytics/*` | `query-api:8080` | Required (JWT + higher rate limit) |
| `/ws/*` | `query-api:8080` | Required (JWT) |
| `/healthz` | `ingestion-api:8080` | Public |

Note the browser only ever learns `localhost:8000`. The `:8080` addresses are internal Docker network names.

### How to verify it works

```bash
curl -i http://localhost:8000/healthz                 # 200, no token needed
curl -i http://localhost:8000/analytics/ohlc?symbol=AAPL   # 401 Unauthorized
curl -i -H "Authorization: Bearer $TOKEN" \
     http://localhost:8000/analytics/ohlc?symbol=AAPL      # 200
```

### Common failure

Getting `401` with a token that "looks fine" → the RSA public key in `infra/kong/kong.yml` is still the placeholder. Copy the real one from Keycloak: *Realm Settings → Keys → RS256 → Public Key*.

---

## Tier 3 — Ingestion & Operational (the Record Keeper)

> Accept writes, validate them, and persist them as the single source of truth.

**Technology:** FastAPI, PostgreSQL 15, Debezium
**Files:** `services/ingestion-api/`, `infra/postgres/init/01-schema.sql`, `infra/debezium/`

### What it does

**Ingestion API** exposes `POST /trades`. It validates the payload and performs a single transactional `INSERT`.

**PostgreSQL** is the system of record. `wal_level=logical` is enabled so the WAL carries enough information for Debezium to decode row-level changes.

**Debezium** tails the WAL and publishes each change to Kafka. It runs as a plugin inside **Kafka Connect**, a framework for moving data in and out of Kafka.

### Why this design

The ingestion service **never publishes to Kafka**. It only writes to PostgreSQL. This is the single most important correctness decision in the platform — see [CDC](#cdc-change-data-capture).

### Two details worth understanding

**Idempotency.** The `trades` table has a unique index on `idempotency_key`, and the insert uses `ON CONFLICT`. Sending the same trade twice does not create a duplicate — the second attempt returns the original row. Without this, any client retry (network blip, double-click) corrupts your trade ledger.

**Replica identity.** `ALTER TABLE trades REPLICA IDENTITY FULL` makes the WAL include every column on `UPDATE` and `DELETE`, not just the primary key. Without it, Debezium would emit incomplete "before" images.

### Key files

| Path | Purpose |
|---|---|
| `app/main.py` | App entry point; wires routes, DB pool, telemetry |
| `app/api/trades.py` | The `POST /trades` handler |
| `app/db/trades_repo.py` | The idempotent `INSERT` query |
| `app/schemas/trade.py` | Pydantic validation contract |
| `infra/postgres/init/01-schema.sql` | Tables, indexes, replicas, roles, publication |
| `infra/debezium/register-postgres-connector.sh` | Registers the CDC connector |

### How to verify it works

```bash
make psql
#   SELECT count(*) FROM trades;
#   SELECT * FROM trades ORDER BY created_at DESC LIMIT 5;
```

Then confirm CDC fired:

```bash
make connectors                        # connector + task state should be RUNNING
make consume TOPIC=dbserver.public.trades
```

### Common failure

Rows in PostgreSQL but nothing in Kafka → check `make connectors`. A `FAILED` task usually means the replication slot or publication is missing. Re-run `bash infra/debezium/register-postgres-connector.sh`.

---

## Tier 4 — Stream Processing (the Factory)

> Turn a raw stream of individual trades into continuously computed aggregates.

**Technology:** Apache Kafka, Apache Flink
**Files:** `services/stream-processor/`, `infra/kafka/`

### What it does

**Kafka** is the durable broker holding the event streams.

**Flink** consumes those streams, performs stateful computation, and emits results. The computation here is **windowed aggregation**.

### The windowing concept

A single trade is not interesting on its own. What's interesting is the *summary over a time period*:

> For all AAPL trades in each 1-minute bucket, compute the opening price, the highest, the lowest, the closing price, and total volume.

That produces an **OHLC candle** — the standard unit of a price chart. Flink does this continuously: it holds each window open, accumulates trades into it, and emits a result when the window closes.

### Why Flink and not a simple script

- **Event-time processing.** Trades carry the time they *occurred*, not the time they arrived. Networks reorder messages. Flink uses **watermarks** to reason about "how late is too late," so a trade arriving 200ms late still lands in the correct window. A naive script would misattribute it.
- **Stateful and fault-tolerant.** Flink periodically **checkpoints** its state. If a worker dies, the job restarts from the last checkpoint and resumes — exactly-once semantics.
- **Parallel.** Work is partitioned by `symbol`, so AAPL and MSFT are processed simultaneously by different workers.

### The two Flink roles

| Role | Responsibility |
|---|---|
| **JobManager** | Coordinator: schedules work, tracks progress, triggers checkpoints, hosts the web UI |
| **TaskManager** | Worker: actually executes operators, holds state |

`parallelism=2` splits work across 2 task slots.

### Topics

| Topic | Direction | Content |
|---|---|---|
| `dbserver.public.trades` | in | CDC events from PostgreSQL |
| `market.prices.live` | in | External market price feed |
| `analytics.ohlc` | out | Computed candles |
| `analytics.risk` | out | Portfolio risk snapshots |
| `livefi.dlq` | out | Dead-letter queue for malformed events |

### Key files

| Path | Purpose |
|---|---|
| `jobs/ohlc_job.py` | Tumbling-window OHLCV computation |
| `jobs/risk_job.py` | Per-portfolio notional exposure |
| `infra/kafka/create-topics.sh` | Creates the topics above |

### How to verify it works

Open the Flink UI at http://localhost:8084 — jobs should show `RUNNING` with checkpoints succeeding.

```bash
make consume TOPIC=analytics.ohlc    # candles should appear within ~1 minute
```

### Common failure

Job stuck in `RESTARTING` → check the Flink UI's exception log. Most often a Kafka connector JAR is missing from `/opt/flink/lib`, or the bootstrap server address is wrong.

---

## Tier 5 — Analytics & Serving (the Library)

> Store computed results in a format optimized for fast reads, and serve them cheaply.

**Technology:** ClickHouse, Redis, FastAPI
**Files:** `services/query-api/`, `infra/clickhouse/init/01-schema.sql`

### What it does

**ClickHouse** stores Flink's output. It is **columnar** — instead of storing rows contiguously, it stores each column contiguously. A query like "scan all prices in this range" reads only the price column, skipping everything else. This is typically orders of magnitude faster than a row store for analytical scans.

**Redis** is an in-memory key-value store used as a cache.

**Query API** is a read-only FastAPI service. It serves analytics and runs the WebSocket. It is deliberately separate from the ingestion service so heavy reads cannot slow down writes.

### The cache-aside pattern

```
request → Redis hit?  → yes → return immediately
                      → no  → query ClickHouse → store in Redis (TTL 5s) → return
```

Hot data is served from memory in microseconds. ClickHouse is only hit on a miss. The 5-second TTL bounds staleness, which is acceptable for analytics.

### Why `ReplacingMergeTree`

Flink guarantees at-least-once delivery — a message may be processed twice. If ClickHouse blindly appended, you would get duplicate candles.

`ReplacingMergeTree(version)` deduplicates rows with the same sorting key, keeping the one with the highest version. So re-processing is harmless. This is what makes the whole pipeline's at-least-once semantics safe at the storage layer.

### Key files

| Path | Purpose |
|---|---|
| `app/api/analytics.py` | `/analytics/ohlc`, `/volume`, `/risk` with cache-aside |
| `app/api/ws.py` | WebSocket subscribe/publish loop |
| `app/core/clickhouse.py` | ClickHouse client + query helper |
| `app/core/cache.py` | Redis helpers: `cached()`, `store()`, `publish()` |
| `infra/clickhouse/init/01-schema.sql` | OLAP tables and materialized views |

### How to verify it works

```bash
make clickhouse
#   SELECT count() FROM livefi.ohlc;
#   SELECT * FROM livefi.trades_raw LIMIT 5;

curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8000/analytics/ohlc?symbol=AAPL" | jq
```

Call it twice — the second response should show `"cached": true`.

### Common failure

`"candles": []` and ClickHouse is empty → nothing is writing to ClickHouse yet. See [Gotchas](#gotchas).

---

## Tier 6 — Observability (the Control Room)

> Make the invisible visible. Answer "is it healthy?" and "why was that slow?"

**Technology:** OpenTelemetry Collector, Prometheus, Jaeger, Grafana
**Files:** `infra/otel/`, `infra/prometheus/`, `infra/grafana/`, `infra/jaeger/`

### The three pillars

| Pillar | Question it answers | Tool |
|---|---|---|
| **Metrics** | Is the system healthy overall? | Prometheus |
| **Traces** | Why was *this specific request* slow? | Jaeger |
| **Logs** | What exactly happened at this moment? | stdout, correlated by trace ID |

Metrics are cheap numbers aggregated over time ("error rate is 2%"). Traces follow one request across every service hop ("Kong took 2ms, ingestion took 400ms, the DB write was the bottleneck"). You need both: metrics tell you *something* is wrong, traces tell you *where*.

### Components

**OpenTelemetry Collector** is a vendor-neutral pipeline. Services send it OTLP data; it processes and forwards to backends. Because instrumentation is OTel-based, swapping Jaeger for another tracing vendor later requires no service code changes.

The collector's pipeline config does something worth noting — **tail sampling** in `otel-collector-config.yml`:
- Keep **100%** of error traces
- Keep **100%** of traces slower than 500ms
- Keep **10%** of everything else

This gives you full detail where it matters and cheap coverage everywhere else, instead of drowning in data or sampling away your bugs.

**Prometheus** scrapes `/metrics` endpoints on a schedule and stores the resulting time series. `rules/livefi.yml` defines alerts, e.g. Kafka consumer lag > 10,000 for 5 minutes, or PostgreSQL replication slot lag > 1GB (which means Debezium has stalled and disk is filling).

**Jaeger** stores and visualizes traces as waterfall diagrams.

**Grafana** renders dashboards. The `provisioning/` files auto-configure datasources on boot, so there's no manual clicking after `docker compose up`.

### How to verify it works

| URL | What to look for |
|---|---|
| http://localhost:9090 | Query `up` — every target should be `1`. Check **Status → Targets**. |
| http://localhost:16686 | Pick a service, find a trace, inspect the waterfall |
| http://localhost:3001 | Datasources already connected under **Connections** |

### Common failure

Prometheus targets show `DOWN` → the service has no `/metrics` endpoint exposed, or it's on a different port than the scrape config expects. Compare `prometheus.yml` against each service's actual port.

---

## A Trade's Full Journey

The clearest way to internalize the tiers. A user clicks "BUY 100 AAPL at $189.42."

| # | Tier | What happens |
|---|---|---|
| 1 | 1 | Browser sends `POST /trades` to `localhost:8000` with `Authorization: Bearer <JWT>` |
| 2 | 2 | **Kong** verifies the JWT signature against Keycloak's public key, checks the rate limit, forwards to `ingestion-api:8080` |
| 3 | 3 | **Ingestion API** validates the payload with Pydantic, runs one idempotent `INSERT`, returns `201` |
| 4 | 3 | **PostgreSQL** writes the row and journals the change to the WAL |
| 5 | 3 | **Debezium** reads the WAL and publishes to topic `dbserver.public.trades` |
| 6 | 4 | **Flink** consumes the event, parses it, assigns it to the AAPL 1-minute window |
| 7 | 4 | Window closes → Flink computes OHLCV → publishes a candle to `analytics.ohlc` |
| 8 | 5 | **Query API** checks **Redis** (miss) → queries **ClickHouse** → caches result |
| 9 | 1 | Browser renders the candle; the **WebSocket** pushes subsequent candles without polling |
| 10 | 6 | Every hop emitted metrics and traces → **OTel** → Prometheus + Jaeger → Grafana |

**Latency budget:** step 3 is milliseconds, steps 5–6 are tens of milliseconds, step 7 is *up to one minute* because that is how long the window stays open. That delay is a deliberate design choice, not a bug — see the next section.

---

## Gotchas

Things that reliably confuse people new to this stack. Read this before debugging.

### 1. `localhost` means something different inside a container

Containers are isolated. `localhost` inside the `query-api` container refers to that container, **not** your laptop.

- Services talk to each other by **service name**: `postgres`, `kafka`, `clickhouse`
- Your browser uses **`localhost`** with a published port

That's why `.env` has `CLICKHOUSE_HOST=clickhouse` while your browser uses `http://localhost:8123`. Same machine, two perspectives. This single misunderstanding causes most "connection refused" errors.

### 2. ClickHouse is empty in the current scaffold

The Flink jobs publish results back to **Kafka** — nothing writes them into ClickHouse yet. So `SELECT count() FROM livefi.ohlc` returning `0` is **expected**, not a bug.

The missing piece is a Kafka → ClickHouse sink. Until that exists, `/analytics/*` has nothing to serve.

### 3. "Real-time" never means instant

It means "within a defined budget." Here: commit (ms) → CDC (tens of ms) → Kafka (ms) → **window close (up to 60s)** → sink → cache.

Real-time systems are always about choosing *where* the latency goes. Need fresher candles? Use a 5-second window. Need fewer writes to ClickHouse? Use a 5-minute window. There is no free lunch.

### 4. This architecture is overkill for small projects — and that's fine

For a weekend project, one PostgreSQL and one backend is genuinely the right answer. This stack earns its complexity through high traffic, multiple teams, strict freshness requirements, and auditability.

Its value here is as a **map of industry-standard tools** and as a place to learn them in isolation. Don't mistake "this is how big systems do it" for "you must always do it this way."

### 5. Docker needs real resources

Kafka, Flink, ClickHouse, and Keycloak together will exhaust Docker Desktop's default 2GB allocation. Symptoms: containers start but never become healthy, or get OOM-killed silently.

**The stack contains four JVM services**, which is why the footprint is large — Java pre-allocates heap aggressively by default.

**Fix, in order of preference:**

1. **Set Docker Desktop to 4 GB** (Settings → Resources → Memory) and use the staged profiles:
   ```bash
   make preflight     # checks Docker is up and reports its memory
   make up-stage1     # ~2.5 GB — postgres, kafka, debezium, ingestion
   make up-stage2     # ~3.5 GB — + clickhouse, redis, query-api
   make mem           # see actual per-container usage
   ```
2. Lower the JVM heap ceilings in `.env` (see the *Resource tuning* section).
3. On a 16 GB machine, `make up-core` runs everything at once.

**Note:** on an 8 GB machine, give Docker at most 4 GB. Allocating more starves macOS itself and makes everything slower, not faster.

### 6. Changes to `init/` SQL only apply to fresh volumes

`infra/postgres/init/*.sql` and `infra/clickhouse/init/*.sql` run **only when the container first starts with an empty data directory**. Editing them and restarting does nothing.

To re-apply:
```bash
make clean    # removes volumes — DESTRUCTIVE, deletes all data
make up-core
```

### 7. Startup order is not instant

`make up-core` returns before the stack is ready. PostgreSQL takes seconds, Keycloak can take 30+, Kafka needs to elect a controller. Always wait for health before concluding something is broken:

```bash
make health
```

`scripts/bootstrap.sh` handles this ordering automatically.

---

## Related Documents

- [`README.md`](../README.md) — architecture overview, install, quickstart
- [`architecture.md`](architecture.md) — ADRs, data contracts, failure modes
- [`diagrams/`](diagrams/) — visual representations
- [`.pi/skills/livefi-platform/SKILL.md`](../.pi/skills/livefi-platform/SKILL.md) — condensed brief for AI agents working in this repo
