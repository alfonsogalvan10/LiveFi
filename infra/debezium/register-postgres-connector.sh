#!/usr/bin/env bash
# ============================================================
# Register the PostgreSQL CDC connector with Debezium.
# Idempotent: re-running updates the existing connector.
# ============================================================
set -euo pipefail

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
CONNECTOR_NAME="${CONNECTOR_NAME:-livefi-postgres-connector}"

PGHOST="${POSTGRES_HOST:-postgres}"
PGPORT="${POSTGRES_PORT:-5432}"
PGDATABASE="${POSTGRES_DB:-livefi}"
PGUSER="${POSTGRES_USER:-livefi}"
PGPASSWORD="${POSTGRES_PASSWORD:-change-me-postgres}"
SLOT_NAME="${DEBEZIUM_SLOT_NAME:-livefi_slot}"
PUBLICATION="${DEBEZIUM_PUBLICATION_NAME:-livefi_publication}"

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
  "table.include.list": "public.trades,public.risk_snapshots",
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

if curl -fsS "${CONNECT_URL}/connectors/${CONNECTOR_NAME}" >/dev/null 2>&1; then
  echo "→ Connector exists — updating configuration"
  curl -fsS -X PUT "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/config" \
    -H 'Content-Type: application/json' -d "$payload" | jq .
else
  echo "→ Creating connector ${CONNECTOR_NAME}"
  curl -fsS -X POST "${CONNECT_URL}/connectors" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg name "$CONNECTOR_NAME" --argjson cfg "$payload" \
          '{name:$name, config:$cfg}')" | jq .
fi

echo "→ Current status:"
curl -fsS "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" | jq '.connector.state, .tasks'
