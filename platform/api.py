import os
import json
import subprocess
from pathlib import Path
from datetime import datetime, timezone
from flask import Flask, jsonify, request

app = Flask(__name__)

# ── Paths ─────────────────────────────────────────────────────────────────────
BASE_DIR    = Path(__file__).parent.parent
ENVS_DIR    = BASE_DIR / "envs"
LOGS_DIR    = BASE_DIR / "logs"
PLATFORM    = BASE_DIR / "platform"
CREATE_SH   = PLATFORM / "create_env.sh"
DESTROY_SH  = PLATFORM / "destroy_env.sh"
OUTAGE_SH   = PLATFORM / "simulate_outage.sh"

def load_state(env_id):
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        return None
    with open(state_file) as f:
        return json.load(f)

def all_envs():
    envs = []
    for f in ENVS_DIR.glob("*.json"):
        try:
            with open(f) as fh:
                envs.append(json.load(fh))
        except Exception:
            pass
    return envs

def ttl_remaining(env):
    created = datetime.fromisoformat(
        env["created_at"].replace("Z", "+00:00")
    )
    now     = datetime.now(timezone.utc)
    elapsed = (now - created).total_seconds()
    return max(0, int(env["ttl"] - elapsed))

# ── POST /envs ────────────────────────────────────────────────────────────────
@app.route("/envs", methods=["POST"])
def create_env():
    data = request.get_json() or {}
    name = data.get("name")
    ttl  = data.get("ttl", 1800)

    if not name:
        return jsonify({"error": "name is required"}), 400

    try:
        result = subprocess.run(
            ["bash", str(CREATE_SH), name, str(ttl)],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return jsonify({
                "error": "Failed to create env",
                "detail": result.stderr
            }), 500

        # Find the newly created env
        envs = all_envs()
        for env in sorted(envs, key=lambda e: e["created_at"], reverse=True):
            if env["name"] == name:
                return jsonify({
                    **env,
                    "ttl_remaining": ttl_remaining(env)
                }), 201

        return jsonify({"error": "Env created but state not found"}), 500

    except subprocess.TimeoutExpired:
        return jsonify({"error": "Timeout creating env"}), 500

# ── GET /envs ─────────────────────────────────────────────────────────────────
@app.route("/envs", methods=["GET"])
def list_envs():
    envs = all_envs()
    result = []
    for env in envs:
        result.append({
            **env,
            "ttl_remaining": ttl_remaining(env)
        })
    return jsonify(result), 200

# ── DELETE /envs/:id ──────────────────────────────────────────────────────────
@app.route("/envs/<env_id>", methods=["DELETE"])
def destroy_env(env_id):
    if not load_state(env_id):
        return jsonify({"error": f"Env {env_id} not found"}), 404

    try:
        result = subprocess.run(
            ["bash", str(DESTROY_SH), env_id],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return jsonify({
                "error": "Failed to destroy env",
                "detail": result.stderr
            }), 500
        return jsonify({"message": f"Env {env_id} destroyed"}), 200

    except subprocess.TimeoutExpired:
        return jsonify({"error": "Timeout destroying env"}), 500

# ── GET /envs/:id/logs ────────────────────────────────────────────────────────
@app.route("/envs/<env_id>/logs", methods=["GET"])
def get_logs(env_id):
    # Check active envs first, then archived
    log_file = LOGS_DIR / env_id / "app.log"
    if not log_file.exists():
        log_file = LOGS_DIR / "archived" / env_id / "app.log"
    if not log_file.exists():
        return jsonify({"error": "Log file not found"}), 404

    with open(log_file) as f:
        lines = f.readlines()

    return jsonify({
        "env_id": env_id,
        "lines": [l.rstrip() for l in lines[-100:]]
    }), 200

# ── GET /envs/:id/health ──────────────────────────────────────────────────────
@app.route("/envs/<env_id>/health", methods=["GET"])
def get_health(env_id):
    health_file = LOGS_DIR / env_id / "health.log"
    if not health_file.exists():
        return jsonify({"error": "Health log not found"}), 404

    with open(health_file) as f:
        lines = f.readlines()

    return jsonify({
        "env_id": env_id,
        "checks": [l.rstrip() for l in lines[-10:]]
    }), 200

# ── POST /envs/:id/outage ─────────────────────────────────────────────────────
@app.route("/envs/<env_id>/outage", methods=["POST"])
def simulate_outage(env_id):
    if not load_state(env_id):
        return jsonify({"error": f"Env {env_id} not found"}), 404

    data = request.get_json() or {}
    mode = data.get("mode")

    if not mode:
        return jsonify({"error": "mode is required"}), 400

    valid_modes = ["crash", "pause", "network", "recover", "stress"]
    if mode not in valid_modes:
        return jsonify({
            "error": f"Invalid mode. Choose from: {valid_modes}"
        }), 400

    try:
        result = subprocess.run(
            ["bash", str(OUTAGE_SH), "--env", env_id, "--mode", mode],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return jsonify({
                "error": "Simulation failed",
                "detail": result.stderr
            }), 500
        return jsonify({
            "message": f"Outage simulation '{mode}' triggered for {env_id}",
            "output": result.stdout
        }), 200

    except subprocess.TimeoutExpired:
        return jsonify({"error": "Timeout running simulation"}), 500

# ── Run ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    port = int(os.environ.get("PLATFORM_PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)
