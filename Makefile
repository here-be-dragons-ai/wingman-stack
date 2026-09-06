SHELL := /bin/bash

# Where the Qwen3.8-27B start scripts live. Only used by `make model` and
# `make watchdog`. Override per call with `make model MLX_REPO=/path`, or set it
# once with `export MLX_REPO=...` in your shell profile.
MLX_REPO  ?= $(HOME)/src/mlx-qwen38-apple-silicon
REPO_DIR  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
START_SH  := $(MLX_REPO)/start-mlx_qwen3.8.sh
WATCHDOG  := $(MLX_REPO)/watchdog-mlx_qwen3.8.sh

# The optional effort guard lives behind a compose profile; targets that must
# see it regardless of whether it runs pass this.
GUARD := --profile guard

# The platform's view of the guard, when the guard is in the path.
GUARD_URL := http://effort-guard:8080/v1

# Toolchain for `make test`. Keep in sync with the build stage of
# effort-guard/Dockerfile, so the tests run on the version the image is built
# with rather than on whatever the floating major tag resolves to today.
GO_IMAGE := golang:1.27-alpine

# Load .env so PROFILE / KV_BITS / WINGMAN_PORT reach the recipes below.
DOTENV := set -a; [ -f "$(REPO_DIR)/.env" ] && . "$(REPO_DIR)/.env"; set +a

.DEFAULT_GOAL := help

.PHONY: help up up-guard down restart logs ps build test doctor model watchdog agent agent-claude

help: ## Show this help
	@echo "Gateway:"
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Order of operations:  make model   (terminal 1, keeps running)"
	@echo "                      make up      (terminal 2)"
	@echo "                      make doctor  (verifies the whole chain)"

# Plain `docker compose up -d` would recreate the platform pointing straight at
# the upstream while leaving a running guard untouched -- up but bypassed, which
# reads as healthy in `make ps`. This is the direct topology, so say so and take
# the guard down with it; `make up-guard` is how you keep it.
up: ## Start the gateway, direct to the backend (removes the effort guard)
	@if docker compose $(GUARD) ps --services --filter status=running 2>/dev/null \
	   | grep -qx effort-guard; then \
	  echo "effort-guard is running; removing it -- 'make up' is the direct topology"; \
	  docker compose $(GUARD) rm -sf effort-guard; \
	fi
	docker compose up -d

up-guard: ## Start the gateway with the optional effort guard in front of the backend
	LLM_URL=$(GUARD_URL) docker compose $(GUARD) up -d --build

down: ## Stop and remove the gateway
	docker compose $(GUARD) down

# Recreating without the guard's profile and LLM_URL would point the platform
# straight at the upstream while leaving the guard container running -- up but
# bypassed, which reads as healthy in `make ps`. So follow whatever is live.
restart: ## Recreate the gateway containers, keeping the current topology
	@if docker compose $(GUARD) ps --services --filter status=running 2>/dev/null \
	   | grep -qx effort-guard; then \
	  echo "effort-guard is running; recreating with the guard in the path"; \
	  LLM_URL=$(GUARD_URL) docker compose $(GUARD) up -d --force-recreate; \
	else \
	  docker compose up -d --force-recreate; \
	fi

logs: ## Follow gateway logs
	docker compose $(GUARD) logs -f

ps: ## Show gateway container status
	docker compose $(GUARD) ps

build: ## Build the effort-guard image
	docker compose $(GUARD) build

test: ## Run the effort-guard unit tests
	docker run --rm -v "$(REPO_DIR)/effort-guard":/src -w /src $(GO_IMAGE) \
	  sh -c 'go vet ./... && go test -v ./...'

doctor: ## Verify model server, gateway and CLI end to end
	@"$(REPO_DIR)/scripts/doctor.sh"

model: ## Start the native Qwen3.8-27B server in the foreground
	@test -x "$(START_SH)" || { \
	  echo "not executable: $(START_SH)"; \
	  echo "override the location with: make model MLX_REPO=/path/to/repo"; \
	  exit 1; }
	@$(DOTENV); \
	CLIENT_CONFIG="$(REPO_DIR)/client.yaml" \
	  caffeinate -dimsu "$(START_SH)"

watchdog: ## Restart the model server before memory fills up
	@test -x "$(WATCHDOG)" || { echo "not executable: $(WATCHDOG)"; exit 1; }
	@$(DOTENV); "$(WATCHDOG)"

agent: ## Run the wingman CLI against the gateway in the current directory
	@command -v wingman >/dev/null || { \
	  echo "wingman not on PATH -- brew install adrianliechti/tap/wingman-cli"; \
	  exit 1; }
	@$(DOTENV); . "$(REPO_DIR)/scripts/wingman-env.sh"; wingman

agent-claude: ## Run the wingman CLI against your Claude subscription (no gateway)
	@command -v wingman >/dev/null || { \
	  echo "wingman not on PATH -- brew install adrianliechti/tap/wingman-cli"; \
	  exit 1; }
	@. "$(REPO_DIR)/scripts/claude-subscription-env.sh"; wingman --agent claude
