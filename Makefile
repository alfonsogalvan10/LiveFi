# ============================================================
# LiveFi — developer shortcuts
# ============================================================
SHELL := /bin/bash
COMPOSE := docker compose
COMPOSE_OBS := docker compose -f docker-compose.yml -f docker-compose.observability.yml

.DEFAULT_GOAL := help
.PHONY: help env up up-core up-observability up-frontend up-all down clean logs ps health \
        up-stage1 up-stage2 up-stage3 up-stage4 preflight mem \
        token psql clickhouse redis topics consume connectors register-connector \
        seed lint test build

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from template if missing
	@test -f .env || (cp .env.example .env && echo "Created .env — edit secrets before production use")

# ---------------- Preflight ----------------
preflight: ## Verify Docker is running and has enough resources
	@docker info >/dev/null 2>&1 || { echo "✗ Docker daemon is not running. Start it with: open -a Docker"; exit 1; }
	@docker info --format '{{.NCPU}} {{.MemTotal}}' | awk '{gb=$$2/1073741824; printf "  Docker: %d CPUs, %.1f GB RAM\n", $$1, gb; if (gb<3.5) {print "  ✗ Needs at least 4 GB. Settings -> Resources -> Memory."; exit 1} else if (gb<6) {print "  ! Under 6 GB available: stages 1-2 only."} else {print "  ✓ Enough for stages 1-4."}}'

mem: ## Show memory + CPU usage per container (useful on low-RAM machines)
	@docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}'

# ---------------- Staged startup ----------------
# Each stage is a superset of the previous one. Start them in order and
# stop whenever your machine runs out of headroom.
up-stage1: env ## Stage 1: postgres+kafka+debezium+ingestion (~2.5 GB) — the CDC pipeline
	$(COMPOSE) --profile stage1 up -d
	@echo ""
	@echo "Stage 1 running. Verify the write -> WAL -> CDC -> Kafka path:"
	@echo "  bash infra/debezium/register-postgres-connector.sh"
	@echo "  SKIP_AUTH=1 API_URL=http://localhost:8080 make seed"
	@echo "  make consume TOPIC=dbserver.public.trades"

up-stage2: env ## Stage 2: + clickhouse+redis+query-api (~3.5 GB) — OLAP storage & reads
	$(COMPOSE) --profile stage2 up -d
	@echo "Stage 2 running. Analytics available on query-api (internal port 8080)."

up-stage3: env ## Stage 3: + flink jobmanager + taskmanager (~5.0 GB) — stream aggregation
	$(COMPOSE) --profile stage3 up -d
	@echo "Stage 3 running. Flink UI: http://localhost:8084"

up-stage4: env ## Stage 4: + keycloak + kong (~6.0 GB) — auth & gateway
	$(COMPOSE) --profile stage4 up -d
	@echo "Stage 4 running. Gateway: http://localhost:8000"

# ---------------- Lifecycle ----------------
up-core: env ## Start the FULL core stack, tiers 1-5 (~7 GB — needs a big machine)
	$(COMPOSE) --profile core up -d
	@echo "Core stack starting. Run 'make health' in ~60s."

up-observability: env ## Start tier 6 (OTel, Prometheus, Jaeger, Grafana)
	$(COMPOSE_OBS) --profile observability up -d

up-frontend: env ## Start the Next.js dashboard
	$(COMPOSE) --profile core --profile frontend up -d frontend

up: up-core up-observability ## Start everything except frontend

up-all: up-core up-observability up-frontend ## Start the whole platform

down: ## Stop containers (keeps volumes)
	$(COMPOSE_OBS) --profile core --profile observability --profile frontend down

clean: ## Stop containers AND delete all volumes/data
	$(COMPOSE_OBS) --profile core --profile observability --profile frontend down -v
	@echo "All volumes removed."

logs: ## Tail logs for all services
	$(COMPOSE) logs -f --tail=100

ps: ## Show running containers
	$(COMPOSE) ps

health: ## Poll health of every container
	@docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# ---------------- Data & messaging ----------------
token: ## Fetch a dev JWT from Keycloak
	@curl -sS -X POST \
	  "http://localhost:$${KEYCLOAK_HTTP_PORT:-8081}/realms/$${KEYCLOAK_REALM:-livefi}/protocol/openid-connect/token" \
	  -d "grant_type=password" \
	  -d "client_id=$${KEYCLOAK_CLIENT_ID:-livefi-web}" \
	  -d "username=demo" -d "password=demo" | jq -r '.access_token'

psql: ## Open a psql shell in the OLTP database
	$(COMPOSE) exec postgres psql -U $${POSTGRES_USER:-livefi} -d $${POSTGRES_DB:-livefi}

clickhouse: ## Open clickhouse-client against the OLAP sink
	$(COMPOSE) exec clickhouse clickhouse-client -u $${CLICKHOUSE_USER:-default} \
	  --password $${CLICKHOUSE_PASSWORD:-change-me-clickhouse} -d $${CLICKHOUSE_DB:-livefi}

redis: ## Open redis-cli
	$(COMPOSE) exec redis redis-cli

topics: ## List Kafka topics
	$(COMPOSE) exec kafka kafka-topics.sh --bootstrap-server localhost:9092 --list

consume: ## Tail a topic: make consume TOPIC=dbserver.public.trades
	$(COMPOSE) exec kafka kafka-console-consumer.sh \
	  --bootstrap-server localhost:9092 --topic $(TOPIC) --from-beginning

connectors: ## List Debezium connectors and their status
	@curl -sS http://localhost:8083/connectors?expand=status | jq

register-connector: ## Register the PostgreSQL CDC connector with Debezium
	@bash ./infra/debezium/register-postgres-connector.sh

seed: ## Generate synthetic market data and trades
	@bash ./scripts/seed.sh

# ---------------- Quality ----------------
lint: ## Lint all services
	@echo "→ Python"; cd services/ingestion-api && ruff check . || true
	@echo "→ Python"; cd services/query-api && ruff check . || true
	@echo "→ Frontend"; cd frontend && pnpm lint || true

test: ## Run unit tests for all services
	cd services/ingestion-api && pytest -q
	cd services/query-api && pytest -q

build: ## Build all custom Docker images
	$(COMPOSE) build
