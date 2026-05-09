#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$PROJECT_ROOT/envs"
LOGS_DIR="$PROJECT_ROOT/logs"

log_health() {
  local ENV_ID="$1"
  local STATUS="$2"
  local LATENCY="$3"
  local TIMESTAMP
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p "$LOGS_DIR/$ENV_ID"
  echo "$TIMESTAMP status=$STATUS latency=${LATENCY}ms" >> "$LOGS_DIR/$ENV_ID/health.log"
}

update_status() {
  local ENV_ID="$1"
  local NEW_STATUS="$2"
  local STATE_FILE="$ENVS_DIR/$ENV_ID.json"
  local TEMP_FILE
  TEMP_FILE=$(mktemp "$ENVS_DIR/.tmp.XXXXXX")
  jq --arg s "$NEW_STATUS" '.status = $s' "$STATE_FILE" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$STATE_FILE"
}

echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Health poller started (PID: $$)"

declare -A FAIL_COUNT

while true; do
  shopt -s nullglob
  STATE_FILES=("$ENVS_DIR"/*.json)
  shopt -u nullglob

  if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] No active environments to poll."
  else
    for STATE_FILE in "${STATE_FILES[@]}"; do
      ENV_ID=$(jq -r '.id' "$STATE_FILE")
      CONTAINER=$(jq -r '.container' "$STATE_FILE")

      FAIL_COUNT["$ENV_ID"]=${FAIL_COUNT["$ENV_ID"]:-0}

      CONTAINER_IP=$(docker inspect -f \
        '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
        "$CONTAINER" 2>/dev/null | head -1)

      if [[ -z "$CONTAINER_IP" ]]; then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] WARNING: Could not get IP for $ENV_ID"
        log_health "$ENV_ID" "unreachable" "0"
        FAIL_COUNT["$ENV_ID"]=$(( FAIL_COUNT["$ENV_ID"] + 1 ))
      else
        # Use curl's built-in time_total for accurate latency
        RESULT=$(curl -s -o /dev/null \
          -w "%{http_code} %{time_total}" \
          --max-time 5 \
          "http://$CONTAINER_IP:5000/health" 2>/dev/null || echo "000 0")

        HTTP_STATUS=$(echo "$RESULT" | awk '{print $1}')
        TIME_SEC=$(echo "$RESULT" | awk '{print $2}')
        # Convert seconds to milliseconds (e.g. 0.012 → 12)
        LATENCY=$(echo "$TIME_SEC * 1000" | awk '{printf "%d", $1 * 1000}')

        log_health "$ENV_ID" "$HTTP_STATUS" "$LATENCY"
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $ENV_ID → HTTP $HTTP_STATUS (${LATENCY}ms)"

        if [[ "$HTTP_STATUS" == "200" ]]; then
          FAIL_COUNT["$ENV_ID"]=0
          CURRENT_STATUS=$(jq -r '.status' "$STATE_FILE")
          if [[ "$CURRENT_STATUS" == "degraded" ]]; then
            update_status "$ENV_ID" "running"
            echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $ENV_ID recovered — status set to running"
          fi
        else
          FAIL_COUNT["$ENV_ID"]=$(( FAIL_COUNT["$ENV_ID"] + 1 ))
        fi
      fi

      if [[ ${FAIL_COUNT["$ENV_ID"]} -ge 3 ]]; then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ⚠️  WARNING: $ENV_ID has failed ${FAIL_COUNT["$ENV_ID"]} consecutive health checks — marking DEGRADED"
        update_status "$ENV_ID" "degraded"
      fi
    done
  fi

  sleep 30
done
