# LiveFi — Real-Time Financial Data Platform

A production-grade, event-driven microservice platform for ingesting, processing, and serving real-time financial data (trades, market prices, risk metrics) with sub-second analytical latency.

The architecture follows a **CDC → Stream → OLAP** pattern: writes land in PostgreSQL (OLTP), Debezium captures them from the WAL, Kafka brokers them, Flink computes stateful windowed aggregations, ClickHouse stores the analytical results, and a read-optimized FastAPI service serves them to a Next.js dashboard that is secured end-to-end by Kong and Keycloak.

> **New to the project, or to distributed systems?** Start with **[docs/tiers-explained.md](docs/tiers-explained.md)**. It walks through each tier in plain language — what it does, why it exists, which files configure it, and how to verify it works. This README is the reference; that document is the tutorial.

---

## Table of Contents

- [Architecture](#architecture)
- [The Six Tiers, Explained (start here)](docs/tiers-explained.md)
- [End-to-End Diagram](#end-to-end-diagram)
- [Repository Layout](#repository-layout)
- [Technology Stack](#technology-stack)
- [Port Map](#port-map)
- [Prerequisites — What You Must Install](#prerequisites--what-you-must-install)
- [Quick Start](#quick-start)
- [Service Reference](#service-reference)
- [Data Flow Walkthrough](#data-flow-walkthrough)
- [Configuration](#configuration)
- [Observability](#observability)
- [Local Development (without Docker)](#local-development-without-docker)
- [Before You Push](#before-you-push)
- [Roadmap](#roadmap)

---

## Architecture

The platform is organized into six tiers. Each tier is independently scalable and only communicates with its neighbors through well-defined contracts (HTTPS/REST, WebSocket, Kafka topics, or SQL).

| # | Tier | Responsibility |
|---|------|----------------|
| 1 | **Client / User** | Interactive dashboard, charts, real-time WebSocket consumption |
| 2 | **Edge & Security** | Token validation, rate limiting, routing, identity management |
| 3 | **Ingestion & Operational** | Accept and persist writes, emit change events |
| 4 | **Event Streaming & Processing** | Durable event log, stateful stream computation |
| 5 | **Analytics & Serving** | Columnar aggregation storage, caching, read APIs |
| 6 | **Observability** | Metrics, traces, logs, and unified dashboards |

### Tier Contracts

- **Client → Edge:** HTTPS + `Authorization: Bearer <JWT>` (issued by Keycloak).
- **Edge → Ingestion:** Reverse-proxied internal HTTP; Kong strips/forwards identity headers.
- **Ingestion → PostgreSQL:** Synchronous SQL `INSERT` inside a transaction (no direct Kafka produce).
- **PostgreSQL → Kafka:** Asynchronous CDC via Debezium reading the logical replication slot.
- **Kafka → Flink:** Exactly-once stream consumption with checkpointing to object storage.
- **Flink → ClickHouse:** Batched, idempotent upserts into `ReplacingMergeTree` tables.
- **Query API → Client:** Redis-cached REST reads + WebSocket push for hot values.

> **Why CDC instead of dual writes?** The ingestion service never publishes to Kafka directly. Debezium derives events from the database transaction log, which guarantees the event stream and the system of record can never diverge (the "dual write" problem).

---

## End-to-End Diagram

```text
[ CLIENT / USER LAYER ]
  │
  ├─ Next.js / React Web App (Frontend Dashboard UI)
  │    ├─ Keycloak OAuth2 / JWT Client SDK
  │    └─ WebSocket Client (Real-time hooks)
  │
  ▼ (HTTPS / WSS + Bearer Token)
[ EDGE & SECURITY LAYER ]
  │
  └─ Kong API Gateway (Port 8000)
       ├─ JWT / OAuth2 Plugin (Validates tokens against Keycloak)
       ├─ Rate Limiting & Security Plugins
       └─ Path-Based Router (/trades ➔ Ingestion, /analytics ➔ Query)
            │
            ├─► Authenticated HTTP ──┐
            │                        ▼
            │               [ INGESTION LAYER ]
            │                 └─ FastAPI Ingestion Service (Port 8080)
            │                      └─ Validates & Commits JSON payloads
            │                           │
            │                           ▼ (SQL Write + WAL Log)
            │               [ STATE & CDC LAYER ]
            │                 ├─ PostgreSQL 15 (Port 5432 - OLTP Source)
            │                 └─ Debezium Kafka Connect (Port 8083)
            │                      └─ Streams DB row changes to Kafka
            │
            ▼ Websocket / REST Query
[ SERVING & CACHING LAYER ]
  ├─ Redis (In-Memory Fast Cache)
  └─ FastAPI Query & Reporting Service (Port 8001)
       └─ Serves aggregated reads back to the frontend UI
            ▲
            │ (Query SQL / Read Updates)
            │
[ ANALYTICS & STREAM PROCESSING CORE ]
  ├─ ClickHouse (Port 8123/9000 - OLAP Columnar Database Sink)
  ├─ Apache Flink Cluster (JobManager / TaskManager)
  │    └─ Executes stateful windowed joins & risk computations
  └─ Apache Kafka Cluster (Port 9092 - Event Broker)
       ├─ Topics: dbserver.public.trades (CDC Stream)
       └─ Topics: market.prices.live (External Feeds Stream)

─────────────────────────────────────────────────────────────
[ OBSERVABILITY & TELEMETRY LAYER ] (Scrapes all components above)
  ├─ OpenTelemetry (OTel) Collector
  ├─ Prometheus (Metrics & System Alerting)
  ├─ Jaeger (Distributed Tracing Pipelines)
  └─ Grafana (Unified Operational Dashboards)
```

---

## Repository Layout

```text
LiveFi/
├── README.md                     ← you are here
├── docker-compose.yml            ← full local stack (all six tiers)
├── docker-compose.observability.yml
├── .env.example                  ← copy to .env and fill in
├── Makefile                      ← one-line dev commands
│
├── docs/
│   ├── tiers-explained.md        ← plain-language tour of all six tiers (start here)
│   ├── architecture.md           ← deeper design notes & ADRs
│   └── diagrams/                 ← exported draw.io / mermaid sources
│
├── .pi/skills/                   ← agent skills (project brief for AI assistants)
│   └── livefi-platform/SKILL.md  ← authoritative statement of project intent
│
├── infra/                        ← infrastructure configuration (no app code)
│   ├── kong/kong.yml             ← declarative gateway routes + plugins
│   ├── keycloak/realm-export.json
│   ├── postgres/init/            ← bootstrap SQL (schema, WAL settings)
│   ├── debezium/                 ← Kafka Connect connector registration
│   ├── kafka/create-topics.sh
│   ├── clickhouse/init/          ← OLAP schema (ReplacingMergeTree)
│   ├── flink/jobs/               ← compiled/uploaded JARs & PyFlink jobs
│   ├── redis/                    ← redis.conf overrides
│   ├── otel/                     ← OTel Collector pipeline config
│   ├── prometheus/               ← scrape configs & alert rules
│   ├── jaeger/                   ← tracing backend config
│   └── grafana/                  ← provisioned datasources + dashboards
│
├── services/                     ← backend microservices
│   ├── ingestion-api/            ← FastAPI: POST /trades → PostgreSQL
│   │   ├── app/{api,core,db,models,schemas}/
│   │   ├── tests/
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   ├── query-api/                ← FastAPI: reads ClickHouse/Redis → UI
│   │   ├── app/{api,core,db,schemas}/
│   │   ├── tests/
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   └── stream-processor/         ← Flink: stateful windowed joins & risk
│       ├── jobs/
│       ├── Dockerfile
│       └── requirements.txt
│
├── frontend/                     ← Next.js dashboard
│   ├── app/                      ← App Router pages & layouts
│   ├── components/               ← charts, tables, WebSocket hooks
│   ├── lib/                      ← API client, Keycloak SDK, WS client
│   ├── public/
│   ├── package.json
│   └── Dockerfile
│
├── scripts/                      ← bootstrap, seeding, teardown helpers
└── .github/workflows/            ← CI: lint, test, build, scan
```

---

## Technology Stack

### 1. Frontend & Client Layer
- **Next.js / React** — dashboard UI (App Router, SSR + client components)
- **Tailwind CSS** — styling
- **TradingView Lightweight Charts** — financial candlestick/line rendering
- **keycloak-js / NextAuth** — OAuth2 PKCE login and silent token refresh

### 2. Edge, Gateway & Authentication Layer
- **Kong Gateway (OSS)** — single ingress, JWT/OAuth2 validation, rate limiting, routing
- **Keycloak** — IAM, realm/client management, JWT issuance, RBAC roles

### 3. Ingestion & Core Operational Layer
- **FastAPI + Uvicorn** — async REST ingestion API
- **PostgreSQL 15** — OLTP system of record, `wal_level=logical`
- **Debezium (Kafka Connect)** — logical replication → Kafka CDC topics

### 4. Event Streaming & Processing Core
- **Apache Kafka (KRaft mode)** — durable, ordered event broker
- **Apache Flink** — stateful streaming, event-time windows, watermarking, risk rules

### 5. Analytics Storage & Serving Layer
- **ClickHouse** — columnar OLAP sink for aggregates and time-series rollups
- **Redis** — cache-aside for hot reads, pub/sub for WebSocket fan-out
- **FastAPI Query Service** — read-optimized API for the dashboard

### 6. Observability & Telemetry Infrastructure
- **OpenTelemetry Collector** — vendor-neutral metric/trace/log pipeline
- **Prometheus** — metrics scraping, recording rules, alerting
- **Jaeger** — distributed tracing across Kong → API → Kafka → Flink
- **Grafana** — unified operational dashboards

---

## Port Map

| Component | Host Port | Purpose |
|---|---|---|
| Frontend (Next.js) | `3000` | Dashboard UI |
| Kong Proxy | `8000` | **Single public entrypoint** |
| Kong Admin API | `8001` | Gateway administration |
| Kong Manager (UI) | `8002` | Optional gateway UI |
| Keycloak | `8081` | IAM / token endpoint |
| Ingestion API | `8080` | Internal only (behind Kong) |
| Query API | `8002` *(container 8001)* | Internal only (behind Kong) |
| PostgreSQL | `5432` | OLTP source of record |
| Kafka | `9092` | Event broker (broker listener) |
| Debezium / Kafka Connect | `8083` | Connector REST API |
| Flink JobManager UI | `8084` | Flink dashboard |
| ClickHouse HTTP | `8123` | OLAP query endpoint |
| ClickHouse Native | `9000` | Native protocol |
| Redis | `6379` | Cache / pub-sub |
| OTel Collector | `4317` / `4318` | gRPC / HTTP ingest |
| Prometheus | `9090` | Metrics & alerting UI |
| Jaeger UI | `16686` | Trace explorer |
| Grafana | `3001` | Operational dashboards |

> **Port conflict fix:** the original blueprint assigned port `8000` to both Kong *and* the ingestion FastAPI service. In this scaffold, **Kong owns `8000`** (public) and the ingestion service listens on **`8080`** (private). Only Kong, the frontend, and the observability UIs should ever be exposed publicly.

---

## Prerequisites — What You Must Install

### Required (Docker path — recommended)

| Tool | Minimum Version | Why | Install (macOS) |
|---|---|---|---|
| **Docker Desktop** | 24+ | Runs the entire stack via Compose | `brew install --cask docker` |
| **Docker Compose v2** | 2.20+ | Bundled with Docker Desktop | included above |
| **Git** | 2.30+ | Version control | `brew install git` |
| **Make** | any | Shortcut commands (`make up`) | preinstalled / `xcode-select --install` |

> Give Docker Desktop at least **8 GB RAM / 4 CPUs** (Settings → Resources). Kafka + Flink + ClickHouse + Keycloak are memory-hungry. This is the single most common cause of a stack that "starts but never becomes healthy."

Check it:

```bash
docker --version          # >= 24
docker compose version    # >= 2.20
git --version
```

### Required for local (non-Docker) development

| Tool | Minimum Version | Why | Install (macOS) |
|---|---|---|---|
| **Python** | 3.11+ | FastAPI services | `brew install python@3.12` |
| **Poetry** *or* `uv` | latest | Python dependency management | `brew install poetry` |
| **Node.js** | 20 LTS+ | Next.js frontend | `brew install node@20` |
| **pnpm** (or npm) | 8+ | Frontend packages | `corepack enable && corepack prepare pnpm@latest --activate` |
| **Java JDK** | 17 (Temurin) | Flink & Kafka Connect runtime | `brew install --cask temurin@17` |

> **You currently do not have Java installed.** Docker will provide it inside the Flink/Debezium containers, so you only need a local JDK if you intend to compile and submit Flink jobs from your host machine.

### Recommended (not required)

| Tool | Why |
|---|---|
| **kcat** (`brew install kcat`) | Inspect Kafka topics from the terminal |
| **psql** (`brew install libpq`) | Query PostgreSQL directly |
| **clickhouse-client** (`brew install clickhouse`) | Query ClickHouse directly |
| **redis-cli** (`brew install redis`) | Inspect the cache |
| **k9s** / **lazydocker** | Terminal TUIs for containers |
| **jq** | Pretty-print JSON payloads and API responses |
| **grpcurl** | Test OTel/collector gRPC endpoints |

### Environment variables / accounts you need

- Nothing external is required to run locally — Keycloak, Kafka, Postgres, etc. all run in containers.
- For production you will need: a **domain + TLS certificate**, an **S3-compatible bucket** (Flink checkpoints/savepoints), and a **container registry**.

### Resource budget

The stack contains **four JVM services** (Kafka, Debezium, Flink ×2, Keycloak). Their default heap sizes are sized for servers, so memory is the binding constraint — more than CPU or disk.

| Resource | Absolute minimum | Comfortable |
|---|---|---|
| CPU | 4 cores | 8 cores |
| RAM | 8 GB (staged) | 16 GB (full stack) |
| Disk | 15 GB free | 30 GB free |

Heap sizes are configurable in `.env` (`KAFKA_HEAP_OPTS`, `CONNECT_HEAP_OPTS`, `KEYCLOAK_JAVA_OPTS`, `FLINK_JOBMANAGER_MEMORY`, `FLINK_TASKMANAGER_MEMORY`) if you need to squeeze the stack further. ClickHouse has its own ceiling in `infra/clickhouse/config.d/01-memory.xml`.

---

## Quick Start

> **On a machine with 8 GB RAM or less?** Use [Staged Startup](#staged-startup-on-limited-hardware) below instead. The full stack needs roughly 7 GB and will thrash on a small host.

### Full stack (~7 GB, 16 GB machine recommended)

```bash
# 1. Clone and enter
git clone <your-repo-url> LiveFi && cd LiveFi

# 2. Create your local environment file
cp .env.example .env

# 3. Bring up tiers 1-5 and the observability tier
make up-core
make up-observability

# 4. Verify
make preflight     # is Docker running with enough memory?
make health
```

### Staged Startup on Limited Hardware

Each stage is a **superset** of the previous one. Start them in order and stop when you run out of headroom.

| Stage | Adds | Est. RAM | What it unlocks |
|---|---|---|---|
| **1** | postgres, kafka, debezium, ingestion-api | ~2.5 GB | The core insight: write → WAL → CDC → Kafka |
| **2** | + clickhouse, redis, query-api | ~3.5 GB | OLAP storage and cached reads |
| **3** | + flink jobmanager + taskmanager | ~5.0 GB | Streaming aggregation |
| **4** | + keycloak, kong | ~6.0 GB | Authentication and the gateway |

```bash
make preflight    # confirm Docker has >= 4 GB
make up-stage1

# Verify the CDC pipeline before adding anything else
bash infra/debezium/register-postgres-connector.sh
SKIP_AUTH=1 API_URL=http://localhost:8080 make seed
make consume TOPIC=dbserver.public.trades

make up-stage2    # then 3, then 4, when you have room
```

Run `make mem` at any point to see actual per-container usage.

**Set Docker Desktop to 4 GB:** Settings → Resources → Memory. On an 8 GB machine, giving Docker more than that starves macOS itself.

### Ports

Then open:

| URL | What |
|---|---|
| http://localhost:8000 | Kong gateway (public API entrypoint) |
| http://localhost:3000 | Frontend dashboard |
| http://localhost:8081 | Keycloak admin (`admin` / value of `KEYCLOAK_ADMIN_PASSWORD`) |
| http://localhost:8084 | Flink dashboard |
| http://localhost:9090 | Prometheus |
| http://localhost:16686 | Jaeger |
| http://localhost:3001 | Grafana (`admin` / value of `GRAFANA_ADMIN_PASSWORD`) |

### Smoke test the pipeline

```bash
# Get a token from Keycloak
TOKEN=$(make token)

# Write a trade through the gateway (Kong validates the JWT, then proxies to ingestion)
curl -sS -X POST http://localhost:8000/trades \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"symbol":"AAPL","side":"BUY","quantity":100,"price":189.42}' | jq

# Confirm it landed in PostgreSQL
make psql
#   SELECT * FROM trades ORDER BY created_at DESC LIMIT 5;

# Confirm Debezium emitted a CDC event
make topics
make consume TOPIC=dbserver.public.trades

# Read the aggregated view back through the gateway
curl -sS http://localhost:8000/analytics/ohlc?symbol=AAPL \
  -H "Authorization: Bearer $TOKEN" | jq
```

---

## Service Reference

### Ingestion API (`services/ingestion-api`)

| Method | Path | Description |
|---|---|---|
| `POST` | `/trades` | Validate and persist a trade to PostgreSQL |
| `GET` | `/healthz` | Liveness probe |
| `GET` | `/readyz` | Readiness probe (checks DB pool) |
| `GET` | `/metrics` | Prometheus metrics |

### Query API (`services/query-api`)

| Method | Path | Description |
|---|---|---|
| `GET` | `/analytics/ohlc` | OHLC candles from ClickHouse (Redis-cached) |
| `GET` | `/analytics/volume` | Aggregated volume by symbol/window |
| `GET` | `/analytics/risk` | Latest risk metrics per portfolio |
| `WS` | `/ws/stream` | Live push of hot aggregates |
| `GET` | `/healthz` | Liveness probe |
| `GET` | `/metrics` | Prometheus metrics |

### Kafka Topics

| Topic | Producer | Consumer | Payload |
|---|---|---|---|
| `dbserver.public.trades` | Debezium | Flink | CDC envelope of a `trades` row |
| `market.prices.live` | External feed ingest | Flink | Normalized tick/quote |
| `analytics.ohlc` | Flink | Query API / ClickHouse sink | 1s/1m OHLC rollups |
| `analytics.risk` | Flink | Query API / ClickHouse sink | Portfolio risk snapshots |
| `_connect-configs`, `_connect-offsets`, `_connect-status` | Kafka Connect | Kafka Connect | Internal Connect state |

---

## Data Flow Walkthrough

> A tier-by-tier version of this walkthrough, with per-tier failure modes, lives in **[docs/tiers-explained.md](docs/tiers-explained.md#a-trades-full-journey)**.

1. **Authenticate.** The Next.js client performs an OAuth2 Authorization Code + PKCE flow against Keycloak and stores the access token.
2. **Submit.** The client `POST`s a trade to Kong at `/trades` with `Authorization: Bearer <JWT>`.
3. **Authorize.** Kong's JWT plugin verifies the signature against Keycloak's JWKS, checks scopes/rate limits, and proxies the request to the ingestion service.
4. **Persist.** FastAPI validates the payload with Pydantic and commits a single row into PostgreSQL.
5. **Capture.** Debezium, tailing PostgreSQL's logical replication slot, emits a change event to `dbserver.public.trades`.
6. **Enrich & compute.** Flink joins the trade stream against `market.prices.live`, applies event-time tumbling windows, computes OHLC/volume/risk, and emits results.
7. **Sink.** Flink writes aggregates into ClickHouse (`ReplacingMergeTree`) and publishes a lightweight notification.
8. **Serve.** The Query API serves reads from Redis (hot path) falling back to ClickHouse (cold path), exposing REST and WebSocket endpoints.
9. **Visualize.** The dashboard renders charts and live-updates via WebSocket.
10. **Observe.** Every hop emits OTel traces/metrics → Collector → Prometheus/Jaeger → Grafana.

---

## Configuration

All runtime configuration lives in `.env` (copied from `.env.example`). Key groups:

| Prefix | Purpose |
|---|---|
| `POSTGRES_*` | OLTP connection and credentials |
| `CLICKHOUSE_*` | OLAP connection |
| `KAFKA_*` | Broker addresses and topic names |
| `REDIS_*` | Cache connection + TTLs |
| `KEYCLOAK_*` | Realm, client ID/secret, issuer URL |
| `KONG_*` | Admin endpoint, rate-limit policy |
| `OTEL_*` | Exporter endpoints and service name |
| `GRAFANA_*` | Admin credentials |

> **Never commit `.env`.** It is already listed in `.gitignore`. Rotate the defaults before any non-local deployment.

---

## Observability

- **Metrics:** each service exposes `/metrics`; Prometheus scrapes every 15s; Grafana provisions datasources automatically from `infra/grafana/provisioning/`.
- **Traces:** OTel SDKs propagate W3C `traceparent` through Kong → FastAPI → Kafka headers → Flink; Jaeger renders end-to-end waterfalls.
- **Logs:** structured JSON to stdout, collected and correlated by `trace_id`.
- **Alerts:** sample rules live in `infra/prometheus/` (consumer lag, API p99 latency, Flink checkpoint failures, Postgres replication slot lag).

---

## Local Development (without Docker)

Run only the infrastructure in Docker and the code you're editing natively:

```bash
# Infrastructure only
docker compose up -d postgres kafka clickhouse redis keycloak kong

# Ingestion API
cd services/ingestion-api
poetry install
uvicorn app.main:app --reload --port 8080

# Query API
cd ../query-api
poetry install
uvicorn app.main:app --reload --port 8001

# Frontend
cd ../../frontend
pnpm install
pnpm dev
```

---

## Before You Push

CI runs on every push and pull request. Run the same checks locally first — it is far faster than waiting for a GitHub runner to tell you something is broken:

```bash
make ci
```

That executes:

| Check | What it catches |
|---|---|
| `ruff check` (both services) | Python lint and import-order problems |
| `pytest` (both services) | Broken logic and failed assertions |
| `pnpm install --frozen-lockfile` | A `package.json` change with a stale lockfile |
| `pnpm lint` | ESLint violations |
| `pnpm typecheck` | TypeScript type errors |
| `pnpm build` | Next.js build failures |
| `docker compose config` | Malformed compose files, across all profiles |

The first run creates virtualenvs under `.venv-ci/` (gitignored) and installs dependencies, so it takes a couple of minutes. Later runs are fast.

Skip slow parts while iterating:

```bash
SKIP_FRONTEND=1 make ci     # Python + compose only
SKIP_BUILD=1 make ci        # frontend lint/typecheck without the build
SKIP_PYTHON=1 make ci
SKIP_COMPOSE=1 make ci
```

**If CI fails on `--frozen-lockfile`**, your `package.json` and `pnpm-lock.yaml` disagree. Run `cd frontend && pnpm install` locally and commit the updated lockfile.

---

## Roadmap

- [ ] Replace single-broker Kafka with a 3-broker KRaft cluster
- [ ] Multi-region ClickHouse with replicated tables
- [ ] Schema Registry (Avro/Protobuf) + backwards-compat enforcement
- [ ] Helm charts for Kubernetes deployment
- [ ] Dead-letter queues and replay tooling for Flink
- [ ] Alertmanager routing to PagerDuty/Slack
- [ ] Load-test harness (k6) with SLO dashboards

---

## License

MIT — see [LICENSE](LICENSE).
