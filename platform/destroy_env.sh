#!/bin/bash
set -euo pipefail

# ── Args ─────────────────────────────────────────────────────────────────────
ENV_ID="${1:-}"

if [[ -z "$ENV_ID" ]]; then
  echo "Usage: $0 <env-id>"
  exit 1
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$PROJECT_ROOT/envs"
LOGS_DIR="$PROJECT_ROOT/logs"
NGINX_CONF_DIR="$PROJECT_ROOT/nginx/conf.d"
STATE_FILE="$ENVS_DIR/$ENV_ID.json"

# ── Validate state file exists ────────────────────────────────────────────────
if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: No state file found for $ENV_ID"
  exit 1
fi

# ── Read state ────────────────────────────────────────────────────────────────
CONTAINER=$(jq -r '.container' "$STATE_FILE")
NETWORK=$(jq -r '.network' "$STATE_FILE")

echo "==> Destroying environment: $ENV_ID"

# ── Kill log shipper ──────────────────────────────────────────────────────────
PID_FILE="$LOGS_DIR/$ENV_ID/log-shipper.pid"
if [[ -f "$PID_FILE" ]]; then
  LOG_PID=$(cat "$PID_FILE")
  echo "==> Killing log shipper (PID: $LOG_PID)"
  kill "$LOG_PID" 2>/dev/null || true
  rm -f "$PID_FILE"
fi

# ── Stop and remove labeled containers ───────────────────────────────────────
echo "==> Stopping and removing containers"
docker ps -q --filter "label=sandbox.env=$ENV_ID" | xargs -r docker rm -f

# ── Disconnect Nginx from env network ─────────────────────────────────────────
echo "==> Disconnecting Nginx from network: $NETWORK"
docker network disconnect "$NETWORK" sandbox-nginx 2>/dev/null || true

# ── Remove Docker network ─────────────────────────────────────────────────────
echo "==> Removing Docker network: $NETWORK"
docker network rm "$NETWORK" 2>/dev/null || true

# ── Delete Nginx config and reload ───────────────────────────────────────────
NGINX_CONF="$NGINX_CONF_DIR/$ENV_ID.conf"
if [[ -f "$NGINX_CONF" ]]; then
  echo "==> Removing Nginx config"
  rm -f "$NGINX_CONF"
  docker exec sandbox-nginx nginx -s reload
fi

# ── Archive logs ──────────────────────────────────────────────────────────────
if [[ -d "$LOGS_DIR/$ENV_ID" ]]; then
  echo "==> Archiving logs"
  mkdir -p "$LOGS_DIR/archived"
  mv "$LOGS_DIR/$ENV_ID" "$LOGS_DIR/archived/$ENV_ID"
fi

# ── Delete state file ─────────────────────────────────────────────────────────
echo "==> Deleting state file"
rm -f "$STATE_FILE"

echo ""
echo "✅ Environment $ENV_ID destroyed successfully"
