#!/usr/bin/env bash
# ============================================================
# Create the LiveFi Kafka topics (idempotent).
# ============================================================
set -euo pipefail

BROKER="${KAFKA_BROKER:-localhost:9092}"
PARTITIONS="${KAFKA_PARTITIONS:-3}"
RF="${KAFKA_REPLICATION_FACTOR:-1}"

TOPICS=(
  "dbserver.public.trades"
  "dbserver.public.risk_snapshots"
  "market.prices.live"
  "analytics.ohlc"
  "analytics.risk"
  "livefi.dlq"
)

for topic in "${TOPICS[@]}"; do
  if kafka-topics.sh --bootstrap-server "$BROKER" --list 2>/dev/null | grep -qx "$topic"; then
    echo "= exists: $topic"
  else
    kafka-topics.sh --bootstrap-server "$BROKER" \
      --create --topic "$topic" \
      --partitions "$PARTITIONS" \
      --replication-factor "$RF" \
      --config retention.ms=86400000
    echo "+ created: $topic"
  fi
done

echo
echo "Current topics:"
kafka-topics.sh --bootstrap-server "$BROKER" --list
