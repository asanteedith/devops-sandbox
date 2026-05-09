# DevOps Sandbox Platform

A self-service platform for spinning up isolated temporary environments, deploying apps, simulating outages, monitoring health, and auto-destroying everything. Think miniature internal Heroku with a chaos engineering toggle.

---

## Architecture
+--------------------------------------------------+
|              Linux VM (Single Host)              |
|                                                  |
|  HTTP :80                                        |
|  User ---------> [ Nginx Container ]             |
|                        |                         |
|              proxy_pass per env                  |
|                        |                         |
|         +--------------+--------------+          |
|         |                             |          |
|  [ net-env-abc / app-env-abc ]  [ net-env-xyz ]  |
|  [ demo-app container        ]  [ demo-app    ]  |
|  [ GET /   GET /health       ]  [ ...         ]  |
|                                                  |
|  HTTP :8080                                      |
|  User ---------> [ Flask API Container ]         |
|                  wraps all bash scripts          |
|                                                  |
|  [ Cleanup Daemon ]     [ Health Poller ]        |
|  loops every 60s        loops every 30s          |
|  destroys expired envs  marks degraded envs      |
|                                                  |
|  envs/*.json   logs/   nginx/conf.d/             |

---

## Prerequisites

- Linux VM (Ubuntu 22.04+)
- Docker Engine 24+
- Docker Compose plugin (`docker compose`)
- `jq`, `curl`, `make`
- Port 80 and 8080 open in your cloud security group

Install missing tools:
```bash
sudo apt-get update && sudo apt-get install -y jq curl make
```

---

## Quick Start (zero to first running env in 5 commands)

```bash
# 1. Clone the repo
git clone https://github.com/YOUR_USERNAME/devops-sandbox.git
cd devops-sandbox

# 2. Build the demo app image
docker build -t demo-app:latest ./demo-app

# 3. Copy and configure environment
cp .env.example .env

# 4. Start the platform
make up

# 5. Create your first environment
make create
```

Your environment is live. Test it:
```bash
curl -H 'Host: <env-id>.localhost' http://localhost:80/
curl -H 'Host: <env-id>.localhost' http://localhost:80/health
```

---

## Full Demo Walkthrough

### 1. Start the platform
```bash
make up
```

### 2. Create an environment
```bash
make create
# Enter name: myapp
# Enter TTL: 1800
```

### 3. Check health status
```bash
make health
```

### 4. Tail logs
```bash
make logs ENV=env-myapp-XXXXX
```

### 5. Simulate an outage
```bash
# Crash the container
make simulate ENV=env-myapp-XXXXX MODE=crash

# Watch health poller detect it within 90s
tail -f logs/poller.log

# Recover
make simulate ENV=env-myapp-XXXXX MODE=recover
```

### 6. Use the Control API
```bash
# List all envs
curl -s http://localhost:8080/envs | jq .

# Create via API
curl -s -X POST http://localhost:8080/envs \
  -H "Content-Type: application/json" \
  -d '{"name":"apienv","ttl":600}' | jq .

# Trigger outage via API
curl -s -X POST http://localhost:8080/envs/<env-id>/outage \
  -H "Content-Type: application/json" \
  -d '{"mode":"pause"}' | jq .

# Destroy via API
curl -s -X DELETE http://localhost:8080/envs/<env-id> | jq .
```

### 7. Watch auto-destroy (short TTL env)
```bash
bash platform/create_env.sh shortlived 70
tail -f logs/cleanup.log
```

### 8. Tear everything down
```bash
make down
```

---

## Makefile Reference

| Command | Description |
|---|---|
| `make up` | Start Nginx, API, cleanup daemon, health poller |
| `make down` | Stop everything, destroy all envs |
| `make create` | Create new env (prompts for name + TTL) |
| `make destroy ENV=<id>` | Destroy specific env |
| `make logs ENV=<id>` | Tail env app logs |
| `make health` | Show all env health statuses |
| `make simulate ENV=<id> MODE=<mode>` | Run outage simulation |
| `make clean` | Wipe all state, logs, archives |

---

## API Reference

| Method | Endpoint | Description |
|---|---|---|
| POST | `/envs` | Create env `{"name":"x","ttl":1800}` |
| GET | `/envs` | List active envs + TTL remaining |
| DELETE | `/envs/:id` | Destroy env |
| GET | `/envs/:id/logs` | Last 100 lines of app.log |
| GET | `/envs/:id/health` | Last 10 health check results |
| POST | `/envs/:id/outage` | Trigger simulation `{"mode":"crash"}` |

---

## Outage Simulation Modes

| Mode | Effect | Recovery |
|---|---|---|
| `crash` | docker kill — immediate SIGKILL | MODE=recover restarts container |
| `pause` | docker pause — freezes all processes | MODE=recover unpauses |
| `network` | Disconnects container from network | MODE=recover reconnects |
| `recover` | Restores whatever was broken | — |
| `stress` | CPU spike via stress-ng for 60s | Auto-recovers after 60s |

---

## Log Shipping

Uses Approach A: `docker logs -f $CONTAINER >> logs/$ENV_ID/app.log &`

PID stored in `logs/$ENV_ID/log-shipper.pid` and killed on destroy to prevent zombie processes.

```bash
make logs ENV=<env-id>
```

---

## Known Limitations

- Single VM only — not designed for multi-host deployments
- Host-header routing — real DNS needed for browser access without -H flag
- No API authentication — do not expose port 8080 publicly
- Demo app only — custom apps need their own image builds
- Flask dev server — use Gunicorn for production
- No log rotation — long-running envs accumulate large log files
