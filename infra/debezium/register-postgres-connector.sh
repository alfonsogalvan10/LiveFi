#!/usr/bin/env bash
# ============================================================
# Register the PostgreSQL CDC connector with Debezium.
# Idempotent: re-running updates the existing connector.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
CONNECTOR_NAME="${CONNECTOR_NAME:-livefi-postgres-connector}"

# Read a single KEY from .env without executing the file. Compose resolves
# .env for the containers, but this script runs on the host, so without this
# the connector would authenticate with the hardcoded fallbacks below. That
# only works while the password happens to match the default — change it in
# .env and registration fails with a confusing auth error.
# Values may contain spaces (KAFKA_HEAP_OPTS=-Xmx512m -Xms256m), so `source`
# is not safe here: the shell would parse the second word as a command.
env_get() {
  [ -f "$ROOT/.env" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$ROOT/.env" | tail -1
}

# Precedence: explicit environment > .env > fallback default.
PGHOST="${POSTGRES_HOST:-$(env_get POSTGRES_HOST)}";          PGHOST="${PGHOST:-postgres}"
PGPORT="${POSTGRES_PORT:-$(env_get POSTGRES_PORT)}";          PGPORT="${PGPORT:-5432}"
PGDATABASE="${POSTGRES_DB:-$(env_get POSTGRES_DB)}";          PGDATABASE="${PGDATABASE:-livefi}"
PGUSER="${POSTGRES_USER:-$(env_get POSTGRES_USER)}";          PGUSER="${PGUSER:-livefi}"
PGPASSWORD="${POSTGRES_PASSWORD:-$(env_get POSTGRES_PASSWORD)}"; PGPASSWORD="${PGPASSWORD:-change-me-postgres}"
SLOT_NAME="${DEBEZIUM_SLOT_NAME:-$(env_get DEBEZIUM_SLOT_NAME)}";       SLOT_NAME="${SLOT_NAME:-livefi_slot}"
PUBLICATION="${DEBEZIUM_PUBLICATION_NAME:-$(env_get DEBEZIUM_PUBLICATION_NAME)}"; PUBLICATION="${PUBLICATION:-livefi_publication}"

echo "→ Waiting for Kafka Connect at ${CONNECT_URL} ..."
for i in $(seq 1 60); do
  if curl -fsS "${CONNECT_URL}/connectors" >/dev/null 2>&1; then break; fi
  sleep 2
  if [ "$i" -eq 60 ]; then echo "✗ Kafka Connect never became ready"; exit 1; fi
done

payload=$(cat <<JSON
{
  "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
  "tasks.max": "1",
  "database.hostname": "${PGHOST}",
  "database.port": "${PGPORT}",
  "database.user": "${PGUSER}",
  "database.password": "${PGPASSWORD}",
  "database.dbname": "${PGDATABASE}",
  "topic.prefix": "dbserver",
  "plugin.name": "pgoutput",
  "slot.name": "${SLOT_NAME}",
  "publication.name": "${PUBLICATION}",
  "publication.autocreate.mode": "disabled",
  "table.include.list": "public.trades,public.market_prices",
  "tombstones.on.delete": "false",
  "decimal.handling.mode": "string",
  "time.precision.mode": "connect",
  "heartbeat.interval.ms": "10000",
  "snapshot.mode": "initial",
  "key.converter": "org.apache.kafka.connect.json.JsonConverter",
  "value.converter": "org.apache.kafka.connect.json.JsonConverter",
  "key.converter.schemas.enable": "false",
  "value.converter.schemas.enable": "false",
  "transforms": "unwrap",
  "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "transforms.unwrap.drop.tombstones": "false",
  "transforms.unwrap.delete.handling.mode": "rewrite"
}
JSON
)

# Perform an HTTP request and fail loudly with the response body.
# `curl -f` alone hides the body, and that body is where Kafka Connect says
# what it rejected — which is the difference between a real error message and
# a bare "error 22".
connect_request() {
  method="$1"; url="$2"; shift 2
  body_file="$(mktemp)"
  status="$(curl -sS -o "$body_file" -w '%{http_code}' -X "$method" "$@" "$url" 2>/dev/null)" || status="000"

  if [ "$status" = "000" ]; then
    echo "✗ ${method} ${url} — could not connect to Kafka Connect."
    echo "  Check the container:  docker compose ps debezium"
    rm -f "$body_file"
    exit 1
  fi

  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "✗ ${method} ${url} → HTTP ${status}"
    jq . <"$body_file" 2>/dev/null || cat "$body_file"
    echo
    echo "  If the body above does not explain it:"
    echo "    available connector classes:"
    echo "      curl -s ${CONNECT_URL}/connector-plugins | jq -r '.[].class'"
    echo "    containers:"
    echo "      docker compose ps"
    rm -f "$body_file"
    exit 1
  fi

  cat "$body_file"
  rm -f "$body_file"
}

# A 404 from this probe is the expected answer for "not registered yet", so it
# is checked by status code rather than treated as an error.
existing="$(curl -sS -o /dev/null -w '%{http_code}' \
  "${CONNECT_URL}/connectors/${CONNECTOR_NAME}" 2>/dev/null)" || existing="000"

if [ "$existing" = "200" ]; then
  echo "→ Connector exists — updating configuration"
  connect_request PUT "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/config" \
    -H 'Content-Type: application/json' -d "$payload" | jq .
else
  echo "→ Creating connector ${CONNECTOR_NAME}"
  connect_request POST "${CONNECT_URL}/connectors" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg name "$CONNECTOR_NAME" --argjson cfg "$payload" \
          '{name:$name, config:$cfg}')" | jq .
fi

echo "→ Current status:"
# A status read can 404 for a moment right after creation, before the herder
# registers the connector. That is not a registration failure, so retry a few
# times and then warn instead of exiting non-zero — the caller verifies too.
registered=""
for _ in $(seq 1 10); do
  if body="$(curl -sS "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" 2>/dev/null)"; then
    if printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$body" | jq '.connector.state, .tasks'
      registered="yes"
      break
    fi
  fi
  sleep 1
done

if [ -z "$registered" ]; then
  echo "! Could not read the connector status yet — it may still be starting."
  echo "  Check with:  make connectors"
fi
