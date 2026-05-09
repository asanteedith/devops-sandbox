.PHONY: up down create destroy logs health simulate clean

# ── Load .env ─────────────────────────────────────────────────────────────────
ifneq (,$(wildcard .env))
  include .env
  export
endif

PLATFORM_PORT ?= 8080
NGINX_PORT    ?= 80

# ── up: start Nginx + API + cleanup daemon + health poller ────────────────────
up:
	@echo "==> Starting Nginx and API..."
	docker compose up -d --build
	@echo "==> Starting cleanup daemon..."
	@mkdir -p logs
	nohup bash platform/cleanup_daemon.sh > logs/cleanup.log 2>&1 &
	@echo $$! > logs/cleanup_daemon.pid
	@echo "==> Starting health poller..."
	nohup bash monitor/health_poller.sh > logs/poller.log 2>&1 &
	@echo $$! > logs/health_poller.pid
	@echo ""
	@echo "✅ Platform is up!"
	@echo "   API:   http://localhost:$(PLATFORM_PORT)"
	@echo "   Nginx: http://localhost:$(NGINX_PORT)"

# ── down: stop everything, destroy all envs ───────────────────────────────────
down:
	@echo "==> Stopping cleanup daemon..."
	@if [ -f logs/cleanup_daemon.pid ]; then \
		kill $$(cat logs/cleanup_daemon.pid) 2>/dev/null || true; \
		rm -f logs/cleanup_daemon.pid; \
	fi
	@echo "==> Stopping health poller..."
	@if [ -f logs/health_poller.pid ]; then \
		kill $$(cat logs/health_poller.pid) 2>/dev/null || true; \
		rm -f logs/health_poller.pid; \
	fi
	@echo "==> Destroying all active environments..."
	@for f in envs/*.json; do \
		[ -f "$$f" ] || continue; \
		ENV_ID=$$(jq -r '.id' "$$f"); \
		echo "    Destroying $$ENV_ID..."; \
		bash platform/destroy_env.sh "$$ENV_ID" || true; \
	done
	@echo "==> Stopping Docker services..."
	docker compose down
	@echo "✅ Platform is down."

# ── create: prompt for name and TTL, then create env ─────────────────────────
create:
	@read -p "Environment name: " name; \
	read -p "TTL in seconds [1800]: " ttl; \
	ttl=$${ttl:-1800}; \
	bash platform/create_env.sh "$$name" "$$ttl"

# ── destroy: destroy a specific env ──────────────────────────────────────────
destroy:
	@if [ -z "$(ENV)" ]; then echo "Usage: make destroy ENV=<env-id>"; exit 1; fi
	bash platform/destroy_env.sh "$(ENV)"

# ── logs: tail logs for a specific env ───────────────────────────────────────
logs:
	@if [ -z "$(ENV)" ]; then echo "Usage: make logs ENV=<env-id>"; exit 1; fi
	@LOG_FILE="logs/$(ENV)/app.log"; \
	if [ ! -f "$$LOG_FILE" ]; then \
		LOG_FILE="logs/archived/$(ENV)/app.log"; \
	fi; \
	if [ ! -f "$$LOG_FILE" ]; then \
		echo "No log file found for $(ENV)"; exit 1; \
	fi; \
	tail -f "$$LOG_FILE"

# ── health: show all env health statuses ─────────────────────────────────────
health:
	@echo "==> Active environment health statuses:"
	@for f in envs/*.json; do \
		[ -f "$$f" ] || continue; \
		ENV_ID=$$(jq -r '.id' "$$f"); \
		STATUS=$$(jq -r '.status' "$$f"); \
		TTL_R=$$(jq -r '.ttl' "$$f"); \
		CREATED=$$(jq -r '.created_at' "$$f"); \
		echo "    $$ENV_ID | status=$$STATUS | created=$$CREATED"; \
		if [ -f "logs/$$ENV_ID/health.log" ]; then \
			echo "    Last check: $$(tail -1 logs/$$ENV_ID/health.log)"; \
		fi; \
	done

# ── simulate: run outage simulation ──────────────────────────────────────────
simulate:
	@if [ -z "$(ENV)" ] || [ -z "$(MODE)" ]; then \
		echo "Usage: make simulate ENV=<env-id> MODE=<crash|pause|network|recover|stress>"; \
		exit 1; \
	fi
	bash platform/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

# ── clean: wipe all state, logs, archives ────────────────────────────────────
clean:
	@echo "==> Wiping all state and logs..."
	@rm -f envs/*.json
	@rm -rf logs/archived/*
	@rm -f logs/*.log logs/*.pid
	@rm -f nginx/conf.d/*.conf
	@echo "✅ Clean complete."
