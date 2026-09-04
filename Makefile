SHELL := /bin/bash

# Where the Qwen3.8-27B start scripts live. Override with MLX_REPO=...
MLX_REPO  ?= $(HOME)/src/m532
REPO_DIR  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
START_SH  := $(MLX_REPO)/start-mlx_qwen3.8.sh
WATCHDOG  := $(MLX_REPO)/watchdog-mlx_qwen3.8.sh

# Load .env so PROFILE / KV_BITS / WINGMAN_PORT reach the recipes below.
DOTENV := set -a; [ -f "$(REPO_DIR)/.env" ] && . "$(REPO_DIR)/.env"; set +a

.DEFAULT_GOAL := help

.PHONY: help up down restart logs ps build test doctor model watchdog agent

help: ## Show this help
	@echo "Gateway:"
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Order of operations:  make model   (terminal 1, keeps running)"
	@echo "                      make up      (terminal 2)"
	@echo "                      make doctor  (verifies the whole chain)"

up: ## Build and start the gateway
	docker compose up -d --build

down: ## Stop and remove the gateway
	docker compose down

restart: ## Recreate the gateway containers
	docker compose up -d --build --force-recreate

logs: ## Follow gateway logs
	docker compose logs -f

ps: ## Show gateway container status
	docker compose ps

build: ## Build the effort-guard image
	docker compose build

test: ## Run the effort-guard unit tests
	docker run --rm -v "$(REPO_DIR)/effort-guard":/src -w /src golang:1-alpine \
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
