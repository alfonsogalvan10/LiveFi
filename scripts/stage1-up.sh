#!/usr/bin/env bash
# ============================================================
# LiveFi — bring up stage 1 and leave it *working*, not just running.
#
# Idempotent: every step is safe to re-run.
#
# ORDER MATTERS. Kafka has auto topic creation enabled, so if the Debezium
# connector is registered before the topics exist, the broker creates
# `dbserver.public.trades` with its own default partition count instead of
# the one in .env. That failure is silent and only shows up later, when
# partitioning or parallelism actually matters. Hence:
#
#   containers -> healthy -> topics -> connector -> verify
#
# Written for bash 3.2 (the version macOS ships): no `mapfile`, no
# associative arrays, no `${arr[@]}` on empty arrays.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMPOSE="docker compose"
KAFKA_BIN="/opt/kafka/bin"
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
CONNECTOR_NAME="${CONNECTOR_NAME:-livefi-postgres-connector}"
# Topics Debezium produces from the published tables. Keep in sync with
# `table.include.list` in infra/debezium/register-postgres-connector.sh and
# with the TOPICS list in infra/kafka/create-topics.sh.
CDC_TOPICS=("dbserver.public.trades" "dbserver.public.market_prices")

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$1"; }
ok()   { printf "    \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "    \033[33m!\033[0m %s\n" "$1"; }
die()  { printf "    \033[31m✗\033[0m %s\n" "$1"; exit 1; }

# Read a single KEY from .env without executing the file. Values may contain
# spaces (e.g. `KAFKA_HEAP_OPTS=-Xmx512m -Xms256m`), which rules out `source`:
# the shell would parse the second word as a command.
env_get() {
  [ -f "$ROOT/.env" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$ROOT/.env" | tail -1
}

# Poll a command until it succeeds, or fail with a useful message.
wait_for() {
  label="$1"; attempts="$2"; shift 2
  i=0
  while [ "$i" -lt "$attempts" ]; do
    if "$@" >/dev/null 2>&1; then
      ok "$label"
      return 0
    fi
    i=$((i + 1))
    sleep 3
  done
  die "$label — gave up after $((attempts * 3))s (try: make logs)"
}

# ------------------------------------------------------------
step "Checking prerequisites"
for cmd in docker curl jq; do
  command -v "$cmd" >/dev/null || die "missing required tool: $cmd"
done
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 required"
ok "docker, curl, jq present"

if ! docker info >/dev/null 2>&1; then
  die "Docker daemon is not running (try: open -a Docker)"
fi
ok "Docker daemon reachable"

# ------------------------------------------------------------
step "Resolving configuration from .env"
if [ ! -f .env ]; then
  cp .env.example .env
  ok "created .env from .env.example"
fi
PGUSER="$(env_get POSTGRES_USER)"; PGUSER="${PGUSER:-livefi}"
PGDB="$(env_get POSTGRES_DB)";     PGDB="${PGDB:-livefi}"
PARTITIONS="$(env_get KAFKA_PARTITIONS)"; PARTITIONS="${PARTITIONS:-3}"
SLOT="$(env_get DEBEZIUM_SLOT_NAME)";     SLOT="${SLOT:-livefi_slot}"
INGEST_PORT="$(env_get INGESTION_SERVICE_PORT)"; INGEST_PORT="${INGEST_PORT:-8080}"
INGEST_URL="${INGEST_URL:-http://localhost:${INGEST_PORT}}"
ok "user=$PGUSER db=$PGDB partitions=$PARTITIONS slot=$SLOT"

# ------------------------------------------------------------
step "Starting stage 1 containers (~2.5 GB)"
$COMPOSE --profile stage1 up -d

# ------------------------------------------------------------
step "Waiting for services to become ready"
wait_for "PostgreSQL ready" 40 \
  $COMPOSE exec -T postgres pg_isready -U "$PGUSER" -d "$PGDB"
# The Kafka CLI tools are not on PATH in the official apache/kafka image.
wait_for "Kafka ready" 40 \
  $COMPOSE exec -T kafka "$KAFKA_BIN/kafka-topics.sh" --bootstrap-server localhost:9092 --list
wait_for "Kafka Connect ready" 60 \
  curl -fsS "$CONNECT_URL/connectors"
wait_for "Ingestion API ready" 40 \
  curl -fsS "$INGEST_URL/healthz"

# ------------------------------------------------------------
# Must happen before the connector is registered — see the header comment.
step "Creating Kafka topics"
$COMPOSE exec -T -e KAFKA_BROKER=localhost:9092 -e KAFKA_PARTITIONS="$PARTITIONS" \
  kafka bash -s < infra/kafka/create-topics.sh

actual=""
for topic in "${CDC_TOPICS[@]}"; do
  actual="$($COMPOSE exec -T kafka "$KAFKA_BIN/kafka-topics.sh" \
    --bootstrap-server localhost:9092 --describe --topic "$topic" 2>/dev/null \
    | grep -c 'Partition:' || true)"
  if [ "$actual" = "$PARTITIONS" ]; then
    ok "$topic has $actual partitions"
  else
    warn "$topic has $actual partitions, expected $PARTITIONS"
    warn "An earlier run let Kafka auto-create it. To fix:"
    warn "  docker compose exec kafka $KAFKA_BIN/kafka-topics.sh --bootstrap-server localhost:9092 \\"
    warn "    --alter --topic $topic --partitions $PARTITIONS"
  fi
done

# ------------------------------------------------------------
step "Registering the Debezium PostgreSQL connector"
# Do NOT silence this script's output: when registration fails, its messages
# are the only thing that says which call failed and why.
bash infra/debezium/register-postgres-connector.sh
ok "connector $CONNECTOR_NAME registered"

step "Waiting for the connector to start streaming"
i=0
while [ "$i" -lt 40 ]; do
  state="$(curl -fsS "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" 2>/dev/null \
    | jq -r '.connector.state // empty')"
  [ "$state" = "RUNNING" ] && break
  i=$((i + 1))
  sleep 3
done
if [ "${state:-}" != "RUNNING" ]; then
  curl -fsS "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" | jq '.tasks[] | select(.state=="FAILED") | .trace'
  die "connector state is '${state:-unknown}' (see trace above)"
fi
ok "connector state RUNNING"

# ------------------------------------------------------------
step "Verifying the replication slot"
i=0
active=""
while [ "$i" -lt 20 ]; do
  active="$($COMPOSE exec -T postgres psql -U "$PGUSER" -d "$PGDB" -tAc \
    "SELECT active FROM pg_replication_slots WHERE slot_name = '$SLOT'" 2>/dev/null | tr -d '[:space:]')"
  [ "$active" = "t" ] && break
  i=$((i + 1))
  sleep 3
done
if [ "$active" = "t" ]; then
  ok "slot $SLOT is active"
else
  die "slot $SLOT is missing or inactive (try: make connectors)"
fi

# ------------------------------------------------------------
step "Stage 1 is ready"
cat <<EOF

  Ingestion API   ${INGEST_URL}          (unauthenticated — Kong arrives in stage 4)
  Kafka           localhost:9094         (host listener)
  Debezium        ${CONNECT_URL}
  PostgreSQL      localhost:5432

  Next:
    make count                                      # row count in Postgres
    SKIP_AUTH=1 API_URL=${INGEST_URL} make seed     # POST sample trades
    make watch                                      # watch them arrive via CDC

EOF
