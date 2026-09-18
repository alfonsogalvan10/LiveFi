# Diagrams

Exported architecture diagrams live here.

Recommended workflow:

1. Author in [draw.io](https://app.diagrams.net/) or Mermaid.
2. Export as `.svg` (crisp at any resolution) plus an editable source.
3. Reference from `README.md` with a relative path.

## Mermaid source (core pipeline)

```mermaid
flowchart LR
    UI[Next.js Dashboard] -->|HTTPS + JWT| KONG[Kong Gateway]
    KONG -->|POST /trades| ING[Ingestion API]
    ING -->|SQL INSERT| PG[(PostgreSQL 15)]
    PG -->|WAL / logical replication| DBZ[Debezium Connect]
    DBZ -->|CDC| K[(Kafka)]
    FEED[Market Feeds] --> K
    K -->|event-time streams| FLINK[Apache Flink]
    FLINK -->|aggregates| K
    FLINK -->|sink| CH[(ClickHouse)]
    KONG -->|GET /analytics| QRY[Query API]
    QRY -->|cache-aside| R[(Redis)]
    QRY -->|OLAP query| CH
    UI <-->|WebSocket| QRY

    subgraph Observability
        OTEL[OTel Collector] --> PROM[Prometheus]
        OTEL --> JAEG[Jaeger]
        PROM --> GRAF[Grafana]
        JAEG --> GRAF
    end
```

## Files

| File | Description |
|---|---|
| `end-to-end.svg` | Full six-tier architecture (to be exported) |
| `data-flow.svg` | Write path: client → Kong → Postgres → Kafka → Flink → ClickHouse |
| `read-path.svg` | Read path: client → Kong → Query API → Redis/ClickHouse |
