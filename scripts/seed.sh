#!/usr/bin/env bash
# ============================================================
# LiveFi — synthetic data generator.
# Emits random trades through the gateway and market ticks to Kafka.
# ============================================================
set -euo pipefail

API_URL="${API_URL:-http://localhost:8000}"
RATE="${RATE:-5}"          # trades per second
DURATION="${DURATION:-60}" # seconds
SYMBOLS=(AAPL MSFT GOOGL TSLA BTC-USD)

# SKIP_AUTH=1 posts straight to the ingestion service without a token.
# Use this in stage 1/2/3 where Kong and Keycloak are not running yet:
#   SKIP_AUTH=1 API_URL=http://localhost:8080 make seed
SKIP_AUTH="${SKIP_AUTH:-0}"

AUTH_HEADER=()
if [ "$SKIP_AUTH" = "1" ]; then
  echo "→ SKIP_AUTH=1 — posting directly to ${API_URL} (no gateway, no token)"
else
  TOKEN="${TOKEN:-}"
  if [ -z "$TOKEN" ]; then
    echo "→ No TOKEN set. Attempting to fetch one from Keycloak..."
    TOKEN=$(curl -sS -X POST \
      "http://localhost:${KEYCLOAK_HTTP_PORT:-8081}/realms/${KEYCLOAK_REALM:-livefi}/protocol/openid-connect/token" \
      -d "grant_type=password" \
      -d "client_id=${KEYCLOAK_CLIENT_ID:-livefi-web}" \
      -d "username=demo" -d "password=demo" 2>/dev/null | jq -r '.access_token // empty')
  fi

  if [ -z "$TOKEN" ]; then
    echo "✗ Could not obtain a token."
    echo "  Either start Keycloak+Kong (make up-stage4) and retry,"
    echo "  or bypass auth entirely:  SKIP_AUTH=1 API_URL=http://localhost:8080 make seed"
    exit 1
  fi
  AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")
fi

echo "→ Emitting ~$((RATE * DURATION)) trades over ${DURATION}s at ${RATE}/s"

end=$(( $(date +%s) + DURATION ))
count=0
while [ "$(date +%s)" -lt "$end" ]; do
  symbol=${SYMBOLS[$((RANDOM % ${#SYMBOLS[@]}))]}
  side=$([ $((RANDOM % 2)) -eq 0 ] && echo BUY || echo SELL)
  qty=$(( (RANDOM % 500) + 1 ))
  price=$(awk -v s="$(echo "scale=2; 50 + $RANDOM % 400" | bc)" 'BEGIN{printf "%.2f", s}')

  curl -sS -o /dev/null -X POST "$API_URL/trades" \
    "${AUTH_HEADER[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"idempotency_key\":\"$(uuidgen | tr '[:upper:]' '[:lower:]')\",\"symbol\":\"$symbol\",\"side\":\"$side\",\"quantity\":$qty,\"price\":$price,\"source\":\"seed\"}" \
    && count=$((count + 1))

  sleep "$(awk -v r="$RATE" 'BEGIN{printf "%.3f", 1/r}')"
done

echo "✓ Sent $count trades"
