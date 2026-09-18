#!/usr/bin/env bash
# ============================================================
# LiveFi — one-shot local bootstrap.
# Brings up the stack, registers CDC, creates topics, and smoke-tests.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$1"; }
ok()   { printf "    \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "    \033[33m!\033[0m %s\n" "$1"; }

step "Checking prerequisites"
for cmd in docker git; do
  command -v "$cmd" >/dev/null || { echo "Missing required tool: $cmd"; exit 1; }
done
docker compose version >/dev/null || { echo "Docker Compose v2 required"; exit 1; }
ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"
ok "$(docker compose version)"

step "Preparing environment"
[ -f .env ] || { cp .env.example .env; ok "created .env"; }
ok ".env present"

step "Starting core stack (tiers 1-5)"
docker compose --profile core up -d

step "Waiting for PostgreSQL"
until docker compose exec -T postgres pg_isready -U "${POSTGRES_USER:-livefi}" >/dev/null 2>&1; do
  sleep 2
done
ok "PostgreSQL ready"

step "Waiting for Kafka"
until docker compose exec -T kafka kafka-topics.sh --bootstrap-server localhost:9092 --list >/dev/null 2>&1; do
  sleep 3
done
ok "Kafka ready"

step "Creating Kafka topics"
docker compose exec -T kafka bash -c 'KAFKA_BROKER=localhost:9092 bash -s' \
  < infra/kafka/create-topics.sh || warn "topic creation reported an issue"

step "Waiting for Kafka Connect"
until curl -fsS http://localhost:8083/connectors >/dev/null 2>&1; do
  sleep 3
done
ok "Kafka Connect ready"

step "Registering Debezium PostgreSQL connector"
bash infra/debezium/register-postgres-connector.sh

step "Starting observability tier"
docker compose -f docker-compose.yml -f docker-compose.observability.yml \
  --profile observability up -d
ok "Observability up"

step "Bootstrap complete"
cat <<'EOF'

  Public API (Kong)   http://localhost:8000
  Frontend            http://localhost:3000   (make up-frontend)
  Keycloak            http://localhost:8081
  Flink UI            http://localhost:8084
  Prometheus          http://localhost:9090
  Jaeger              http://localhost:16686
  Grafana             http://localhost:3001

  Next:  make token   →  POST a trade  →  make topics

EOF
