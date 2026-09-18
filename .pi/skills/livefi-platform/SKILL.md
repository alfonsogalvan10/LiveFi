---
name: livefi-platform
description: Orientation brief for the LiveFi real-time financial data platform. Explains the six-tier architecture (Next.js → Kong/Keycloak → FastAPI/PostgreSQL/Debezium → Kafka/Flink → ClickHouse/Redis → observability), the design rules that must not be violated, repo conventions, current gaps, and how to run the stack. Use whenever working on any LiveFi service, infrastructure config, docker-compose, or when the user asks what the project is, how data flows through it, why a component exists, or how to run or debug it.
---

# LiveFi Platform

> **Loaded because:** the task touches this repository's architecture, services, or infrastructure. Read this before making structural changes or answering "why is this here?" questions.

## Mission

LiveFi is a **real-time financial data platform**: ingest trades, compute streaming analytics, and serve a live dashboard with sub-second read latency.

Concretely, it demonstrates the industry-standard **CDC → Stream → OLAP** pattern — writes land in an operational database, changes are captured from its transaction log, streamed through a broker, computed by a stream processor, stored in a columnar analytics database, and served from a cache.

The project doubles as a **learning scaffold**. The user is new to distributed systems. Prefer explaining *why* a component exists over assuming familiarity. See [Working with this user](#working-with-this-user).

## The problem it solves

A single database + backend breaks under real-time analytical load for three reasons:

1. **Analytics queries starve writes.** Scanning millions of rows for a chart monopolizes resources; concurrent trade inserts slow down or time out.
2. **Polling is wasteful.** Re-running an expensive query every few seconds to show a small delta burns resources for little value.
3. **Coupling creates fragility.** One slow query path degrades the entire system.

The architecture separates write, compute, and read paths so each can fail and scale independently.

## Core concepts

| Concept | Meaning | Why it's here |
|---|---|---|
| **OLTP vs OLAP** | Transactional (many small ops) vs analytical (few huge scans) | PostgreSQL vs ClickHouse — different engines for different workloads |
| **Event streaming** | Durable ordered log; producers post, consumers read | Kafka decouples services; consumers can lag, restart, or be added freely |
| **CDC** | Derive events from the database's write-ahead log | Eliminates the dual-write problem — see [Design rules](#design-rules-non-negotiable) |
| **Event-time windowing** | Group events by when they occurred, not when they arrived | Correct aggregation under network reordering and late arrivals |
| **Cache-aside** | Check cache, fall through to DB on miss, store result | Fast repeated reads without hammering the analytical store |
| **Idempotency** | Same operation applied twice has the same effect as once | Makes retries and at-least-once delivery safe |

## The six tiers

| Tier | Components | Responsibility |
|---|---|---|
| 1. Client | Next.js, React, Tailwind, TradingView Charts | Dashboard UI, auth flow, WebSocket consumption |
| 2. Edge | Kong Gateway, Keycloak | Single public entrypoint; JWT validation, rate limiting, routing |
| 3. Ingestion | FastAPI, PostgreSQL 15, Debezium | Validate + persist writes; emit CDC events from the WAL |
| 4. Streaming | Apache Kafka, Apache Flink | Durable event log; stateful windowed aggregation |
| 5. Serving | ClickHouse, Redis, FastAPI | OLAP storage, cache-aside reads, WebSocket push |
| 6. Observability | OTel Collector, Prometheus, Jaeger, Grafana | Metrics, traces, alerts, dashboards |

**Full explanations, verification steps, and per-tier failure modes:** [`docs/tiers-explained.md`](../../../docs/tiers-explained.md). Read it before answering architecture questions in depth.

## Data flow

```
Browser → Kong (verify JWT) → Ingestion API → PostgreSQL
                                                   │ WAL
                                                   ▼
                                               Debezium
                                                   │ CDC
                                                   ▼
                            Kafka ◄───────────────┘
                              │  topic: dbserver.public.trades
                              ▼
                            Flink  (keyBy symbol → 1-min tumbling window → OHLCV)
                              │
                              ▼
                            Kafka  topic: analytics.ohlc
                              │
                              ▼
                    ClickHouse (ReplacingMergeTree)
                              │
                              ▼
             Query API ◄─ Redis (cache-aside) ─→ Browser (REST + WebSocket)
```

## Design rules (non-negotiable)

Violating these breaks a guarantee the platform depends on. Flag them if you see them in code or if a request would require them.

1. **The ingestion service must never publish to Kafka directly.**
   Events come *only* from Debezium reading the PostgreSQL WAL. Writing to both the DB and Kafka is the dual-write problem — a crash between the two writes leaves the database and the event stream permanently inconsistent. This is the single most important rule in the codebase.

2. **Kong is the only public entrypoint.**
   No internal service should be exposed on a host port for anything other than diagnostics. Authentication and rate limiting live in Kong, not in individual services.

3. **Writes go to PostgreSQL, reads come from ClickHouse.**
   Never serve analytical queries from the OLTP database. That reintroduces the coupling the architecture exists to prevent.

4. **All writes must be idempotent.**
   Ingestion uses a unique `idempotency_key` with `ON CONFLICT`. ClickHouse uses `ReplacingMergeTree(version)`. New write paths need an equivalent mechanism, because Kafka delivery is at-least-once.

5. **Never commit `.env`.**
   Only `.env.example` is versioned. Secrets, keys, and passwords stay out of git.

## Repository conventions

### Where things go

| Location | Contents | Rule |
|---|---|---|
| `infra/` | Third-party tool **configuration** | No application code |
| `services/` | Backend **code we write** | One directory per service |
| `frontend/` | Next.js app | — |
| `docs/` | Design rationale, ADRs, explanations | — |
| `scripts/` | Operational helper scripts | Must be idempotent |
| `.pi/skills/` | Agent skills | — |

### Service layout (both FastAPI services follow this)

```
app/
├── main.py          # entrypoint: wires routers, lifespan, telemetry
├── api/             # HTTP route handlers (thin — delegate to db/, core/)
├── core/            # config.py (typed settings), telemetry.py, clients
├── db/              # database queries and connection management
└── schemas/         # Pydantic request/response contracts
tests/
Dockerfile
requirements.txt
```

New FastAPI services must match this structure. Configuration is read from environment variables via a typed `Settings` class — never hardcoded.

### Port map

| Service | Host port | Public? |
|---|---|---|
| Kong proxy | 8000 | **Yes — the only backend entrypoint** |
| Frontend | 3000 | Yes |
| Keycloak | 8081 | Yes (admin) |
| PostgreSQL | 5432 | No |
| Kafka | 9092 / 9094 | No |
| Kafka Connect (Debezium) | 8083 | No |
| Flink UI | 8084 | Yes (ops) |
| ClickHouse | 8123 / 9000 | No |
| Redis | 6379 | No |
| Query API | 8001 → container 8080 | No |
| Ingestion API | 8080 | No |
| Prometheus | 9090 | Yes (ops) |
| Grafana | 3001 | Yes (ops) |
| Jaeger | 16686 | Yes (ops) |

> Historical note: the original blueprint assigned port `8000` to both Kong and the ingestion service. Resolved by giving Kong `8000` and moving ingestion to `8080`. See ADR-002 in `docs/architecture.md`.

## Current state

### Working

- Full Docker Compose stack for all six tiers, profile-based (`core`, `observability`, `frontend`)
- PostgreSQL schema with logical replication, publication, and Debezium role
- Debezium connector registration script (idempotent)
- ClickHouse OLAP schema with `ReplacingMergeTree` tables and a materialized view
- Kong declarative routing with JWT + rate limiting + CORS + correlation ID
- Both FastAPI services with working handlers, health probes, tests, and telemetry
- Flink OHLC job (complete) and risk job (state accumulation is a stub)
- Observability pipeline with tail sampling and alert rules
- Makefile, bootstrap/seed/teardown scripts, CI workflow

### Known gaps

Be honest about these — do not imply they work.

| Gap | Detail |
|---|---|
| **No Kafka → ClickHouse sink** | Flink publishes to Kafka; nothing writes to ClickHouse. `SELECT count() FROM livefi.ohlc` returns 0. This is the highest-value next task. |
| Kong public key is a placeholder | `infra/kong/kong.yml` has a TODO where Keycloak's RS256 public key belongs. As shipped, JWT validation will fail. |
| Keycloak realm is a stub | `realm-export.json` is hand-written, not exported from a configured instance. |
| Risk job is skeletal | `jobs/risk_job.py` computes notional but has no keyed state or rolling volatility. |
| Frontend is one page | `app/page.tsx` is a demo. No auth wiring, no real Keycloak adapter. |
| Single broker / single node | Kafka replication factor 1, one ClickHouse node. Fine locally, not production. |

## How to run

```bash
cp .env.example .env      # first time only
make preflight            # verify Docker is running with enough memory
```

**The stack is staged.** Each profile is a superset of the previous one, which matters because the full core stack needs ~7 GB and the four JVM services will exhaust a small host.

| Stage | Adds | Est. RAM |
|---|---|---|
| `make up-stage1` | postgres, kafka, debezium, ingestion-api | ~2.5 GB |
| `make up-stage2` | + clickhouse, redis, query-api | ~3.5 GB |
| `make up-stage3` | + flink jobmanager + taskmanager | ~5.0 GB |
| `make up-stage4` | + keycloak, kong | ~6.0 GB |
| `make up-core` | tiers 1-5 in one go | ~7.0 GB |
| `make up-observability` | tier 6 (merged file, separate profile) | +1 GB |

Helper commands: `make mem` (per-container usage), `make psql`, `make clickhouse`, `make redis`, `make topics`, `make consume TOPIC=...`, `make connectors`, `make token`, `make seed`, `make logs`, `make down`, `make clean` (destructive).

**In stages 1-3 there is no Kong or Keycloak**, so `make seed` cannot fetch a token. Post straight to the ingestion service instead:

```bash
SKIP_AUTH=1 API_URL=http://localhost:8080 make seed
```

First startup takes several minutes. `scripts/bootstrap.sh` runs the full setup in the correct dependency order.

## Debugging guide

| Symptom | Likely cause |
|---|---|
| `401` with a valid-looking token | Kong RSA public key is still the placeholder |
| Rows in Postgres, nothing in Kafka | Debezium task failed — `make connectors`, then re-register |
| ClickHouse empty | Expected — the Kafka → ClickHouse sink does not exist yet |
| `connection refused` between services | Using `localhost` instead of the Docker service name |
| Container starts, never healthy | Docker Desktop out of memory |
| SQL edits in `infra/*/init/` have no effect | Init scripts only run on a fresh volume — `make clean` then `make up-core` |
| Prometheus target `DOWN` | Scrape config port doesn't match the service's actual port |

## Working with this user

- **Assume no distributed-systems background.** Define terms on first use. Explain *why* a component exists, not just what it does.
- **Prefer concrete over abstract.** Trace a single request through the system rather than describing tiers in the abstract.
- **Flag design trade-offs explicitly.** State what a choice costs, not only what it buys.
- **Distinguish scaffold from production.** Much here is deliberately single-node or stubbed. Say so rather than implying completeness.
- **Never claim a gap is implemented.** Check "Known gaps" above and verify against the code.
- **When adding a component, say which tier it belongs to** and which files change.
- The user has referred to this skill deliberately — treat it as the authoritative statement of project intent.

## Related documents

- [`docs/tiers-explained.md`](../../../docs/tiers-explained.md) — deep per-tier explanations, verification steps, gotchas
- [`docs/architecture.md`](../../../docs/architecture.md) — ADRs, data contracts, failure matrix
- [`README.md`](../../../README.md) — install requirements, quickstart, port map
- [`docker-compose.yml`](../../../docker-compose.yml) — the actual service definitions
