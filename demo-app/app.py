from flask import Flask, jsonify
import os

app = Flask(__name__)

ENV_ID = os.environ.get("ENV_ID", "unknown")

@app.route("/")
def index():
    return jsonify({
        "message": "Hello from the sandbox!",
        "env_id": ENV_ID
    })

@app.route("/health")
def health():
    return jsonify({"status": "ok", "env_id": ENV_ID}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
