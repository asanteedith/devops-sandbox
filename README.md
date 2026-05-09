# DevOps Sandbox Platform

A self-service platform for spinning up isolated temporary environments, deploying apps, simulating outages, monitoring health, and auto-destroying everything. Think miniature internal Heroku with a chaos engineering toggle.

---

## Architecture

```
+--------------------------------------------------+
|            Linux VM (Single Host)                |
|                                                  |
|  User --HTTP:80--> [ Nginx Container ]           |
|                           |                      |
|              +------------+------------+         |
|              |                         |         |
|   [ net-env-abc / app-env-abc ]  [ net-env-xyz ] |
|   [ demo-app:latest           ]  [ demo-app    ] |
|   [ GET /    GET /health      ]                  |
|                                                  |
|  User --HTTP:8080--> [ Flask API Container ]     |
|                      wraps all bash scripts      |
|                                                  |
|  [ Cleanup Daemon ]    [ Health Poller ]         |
|    every 60s               every 30s             |
|    auto-destroys           marks degraded        |
|                                                  |
|  envs/*.json   logs/   nginx/conf.d/             |
+--------------------------------------------------+
```

---

## Prerequisites

- Linux VM (Ubuntu 22.04+)
- Docker Engine 24+
- Docker Compose plugin (`docker compose`)
- `jq`, `curl`, `make`
- Port 80 and 8080 open in security group

```bash
sudo apt-get update && sudo apt-get install -y jq curl make
```

---

## Quick Start

```bash
git clone https://github.com/asanteedith/devops-sandbox.git
cd devops-sandbox
docker build -t demo-app:latest ./demo-app
cp .env.example .env
make up
make create
```

---

## Full Demo Walkthrough

```bash
# Start platform
make up

# Create environment
make create

# Test it
curl -H 'Host: <env-id>.localhost' http://localhost:80/
curl -H 'Host: <env-id>.localhost' http://localhost:80/health

# Check health
make health

# Simulate crash
make simulate ENV=<env-id> MODE=crash

# Recover
make simulate ENV=<env-id> MODE=recover

# Auto-destroy demo
bash platform/create_env.sh shortlived 70
tail -f logs/cleanup.log

# API
curl -s http://localhost:8080/envs | jq .

# Shut down
make down
```

---

## Makefile Reference

| Command | Description |
|---|---|
| `make up` | Start Nginx, API, daemon, poller |
| `make down` | Stop everything |
| `make create` | Create new env |
| `make destroy ENV=<id>` | Destroy specific env |
| `make logs ENV=<id>` | Tail env logs |
| `make health` | Show all env health |
| `make simulate ENV=<id> MODE=<mode>` | Run outage simulation |
| `make clean` | Wipe all state and logs |

---

## API Reference

| Method | Endpoint | Description |
|---|---|---|
| POST | `/envs` | Create env |
| GET | `/envs` | List envs + TTL |
| DELETE | `/envs/:id` | Destroy env |
| GET | `/envs/:id/logs` | Last 100 log lines |
| GET | `/envs/:id/health` | Last 10 health checks |
| POST | `/envs/:id/outage` | Trigger simulation |

---

## Outage Modes

| Mode | Effect |
|---|---|
| `crash` | Kills container immediately |
| `pause` | Freezes all processes |
| `network` | Disconnects from network |
| `recover` | Restores whatever was broken |
| `stress` | CPU spike for 60s |

---

## Known Limitations

- Single VM only
- Host-header routing — real DNS needed for browser access
- No API authentication
- Flask dev server — use Gunicorn for production
- No log rotation
