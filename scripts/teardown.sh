#!/usr/bin/env bash
# ============================================================
# LiveFi — stop everything and optionally delete all data.
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIRM="${1:-}"

docker compose -f docker-compose.yml -f docker-compose.observability.yml \
  --profile core --profile observability --profile frontend down

if [ "$CONFIRM" = "--purge" ]; then
  read -r -p "Delete ALL volumes (Postgres, ClickHouse, Kafka, Redis)? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    docker compose -f docker-compose.yml -f docker-compose.observability.yml \
      --profile core --profile observability --profile frontend down -v
    echo "✓ Volumes removed"
  else
    echo "Aborted — volumes kept"
  fi
else
  echo "✓ Containers stopped (data volumes preserved). Use --purge to wipe data."
fi
