#!/bin/bash
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$PROJECT_ROOT/envs"
LOGS_DIR="$PROJECT_ROOT/logs"
CLEANUP_LOG="$LOGS_DIR/cleanup.log"
DESTROY_SCRIPT="$SCRIPT_DIR/destroy_env.sh"

mkdir -p "$LOGS_DIR"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$CLEANUP_LOG"
}

log "==> Cleanup daemon started (PID: $$)"

while true; do
  log "==> Scanning envs/ for expired environments..."

  # Check if any state files exist
  shopt -s nullglob
  STATE_FILES=("$ENVS_DIR"/*.json)
  shopt -u nullglob

  if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
    log "    No active environments found."
  else
    for STATE_FILE in "${STATE_FILES[@]}"; do
      ENV_ID=$(jq -r '.id' "$STATE_FILE")
      CREATED_AT=$(jq -r '.created_at' "$STATE_FILE")
      TTL=$(jq -r '.ttl' "$STATE_FILE")

      # Convert created_at to epoch seconds
      CREATED_EPOCH=$(date -d "$CREATED_AT" +%s)
      NOW_EPOCH=$(date -u +%s)
      EXPIRES_AT=$((CREATED_EPOCH + TTL))

      if [[ "$NOW_EPOCH" -ge "$EXPIRES_AT" ]]; then
        log "==> Environment $ENV_ID has EXPIRED — destroying..."
        bash "$DESTROY_SCRIPT" "$ENV_ID" >> "$CLEANUP_LOG" 2>&1
        log "==> Environment $ENV_ID destroyed by daemon."
      else
        REMAINING=$((EXPIRES_AT - NOW_EPOCH))
        log "    $ENV_ID is active — ${REMAINING}s remaining."
      fi
    done
  fi

  log "==> Next scan in 60 seconds."
  sleep 60
done
