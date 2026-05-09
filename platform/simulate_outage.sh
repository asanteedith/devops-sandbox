#!/bin/bash
set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)   ENV_ID="$2";  shift 2 ;;
    --mode)  MODE="$2";    shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
  echo "Usage: $0 --env <env-id> --mode <crash|pause|network|recover|stress>"
  exit 1
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$PROJECT_ROOT/envs"
STATE_FILE="$ENVS_DIR/$ENV_ID.json"

# ── Validate state file ───────────────────────────────────────────────────────
if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: No state file found for $ENV_ID"
  exit 1
fi

CONTAINER=$(jq -r '.container' "$STATE_FILE")
NETWORK=$(jq -r '.network' "$STATE_FILE")

# ── GUARD — never simulate against Nginx or daemon ────────────────────────────
PROTECTED=("sandbox-nginx" "cleanup_daemon" "sandbox-api")
for PROTECTED_NAME in "${PROTECTED[@]}"; do
  if [[ "$CONTAINER" == *"$PROTECTED_NAME"* ]]; then
    echo "ERROR: Refusing to simulate outage against protected container: $CONTAINER"
    exit 1
  fi
done

echo "==> Outage simulation: mode=$MODE env=$ENV_ID container=$CONTAINER"

case "$MODE" in

  crash)
    echo "==> [crash] Killing container $CONTAINER"
    docker kill "$CONTAINER"
    echo "✅ Container killed. Health monitor should detect within 90s."
    ;;

  pause)
    echo "==> [pause] Pausing container $CONTAINER"
    docker pause "$CONTAINER"
    echo "✅ Container paused. Recover with: $0 --env $ENV_ID --mode recover"
    ;;

  network)
    echo "==> [network] Disconnecting $CONTAINER from network $NETWORK"
    docker network disconnect "$NETWORK" "$CONTAINER"
    echo "✅ Network disconnected. Recover with: $0 --env $ENV_ID --mode recover"
    ;;

  recover)
    echo "==> [recover] Attempting recovery for $ENV_ID"

    # Check if container is paused → unpause
    STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")

    if [[ "$STATUS" == "paused" ]]; then
      echo "    Container is paused — unpausing..."
      docker unpause "$CONTAINER"
      echo "✅ Container unpaused."

    elif [[ "$STATUS" == "exited" || "$STATUS" == "dead" || "$STATUS" == "missing" ]]; then
      echo "    Container is down — restarting..."
      docker start "$CONTAINER" 2>/dev/null || \
        docker run -d \
          --name "$CONTAINER" \
          --network "$NETWORK" \
          --label "sandbox.env=$ENV_ID" \
          -e "ENV_ID=$ENV_ID" \
          demo-app:latest
      echo "✅ Container restarted."

    else
      # Check if disconnected from network — reconnect
      CONNECTED=$(docker inspect "$CONTAINER" \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
        2>/dev/null || echo "")

      if [[ "$CONNECTED" != *"$NETWORK"* ]]; then
        echo "    Container disconnected from network — reconnecting..."
        docker network connect "$NETWORK" "$CONTAINER"
        echo "✅ Network reconnected."
      else
        echo "    Container status: $STATUS — nothing to recover."
      fi
    fi

    # Reset status back to running
    TEMP_FILE=$(mktemp "$ENVS_DIR/.tmp.XXXXXX")
    jq '.status = "running"' "$STATE_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$STATE_FILE"
    echo "✅ Status reset to running."
    ;;

  stress)
    # Optional — requires stress-ng
    if ! command -v stress-ng &>/dev/null; then
      echo "==> Installing stress-ng..."
      sudo apt-get install -y stress-ng
    fi
    echo "==> [stress] Spiking CPU in container $CONTAINER for 60 seconds"
    docker exec "$CONTAINER" sh -c \
      "apt-get install -y stress-ng -qq && stress-ng --cpu 2 --timeout 60s" &
    echo "✅ Stress test started for 60s."
    ;;

  *)
    echo "ERROR: Unknown mode '$MODE'. Use: crash|pause|network|recover|stress"
    exit 1
    ;;
esac
