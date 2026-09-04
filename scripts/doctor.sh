#!/usr/bin/env bash
#
# Verifies the whole chain: native model server -> effort guard -> wingman
# platform -> wingman CLI. Every check is independent and reports on its own,
# so one failure still tells you the state of everything else.
#
#   ./scripts/doctor.sh
#
# Override anything via the environment:
#   MODEL_URL=http://localhost:8899 ./scripts/doctor.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck disable=SC1091
if [ -f .env ]; then set -a; . ./.env; set +a; fi

MODEL_URL="${MODEL_URL:-http://localhost:8888}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:${WINGMAN_PORT:-4242}}"
MODEL_ALIAS="${LLM_MODEL:-Qwen3.8-27B-local}"
GATEWAY_MODEL="${WINGMAN_MODEL:-qwen3.8-27b}"

# A cold prefill on this model takes minutes, so inference checks get a long
# timeout while reachability checks stay snappy.
REQ_TIMEOUT="${REQ_TIMEOUT:-180}"

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; DIM=''; OFF=''
fi

failed=0

pass() { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$OFF" "$1"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$OFF" "$1"; failed=$((failed + 1)); }
note() { printf '    %s%s%s\n' "$DIM" "$1" "$OFF"; }
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$OFF"; }

# ── 1. Model server ───────────────────────────────────────────────────────────

section "1. Native model server ($MODEL_URL)"

models_body=$(curl -fsS -m 5 "$MODEL_URL/v1/models" 2>&1)

if [ $? -ne 0 ]; then
  fail "not reachable"
  note "start it with: make model"
  note "curl said: $(printf '%s' "$models_body" | head -1)"
else
  pass "reachable"

  if printf '%s' "$models_body" | grep -q -- "$MODEL_ALIAS"; then
    pass "serves the expected alias '$MODEL_ALIAS'"
  else
    fail "alias '$MODEL_ALIAS' is not in /v1/models"
    note "with mlx-vlm the request model name is the load path, so a mismatch"
    note "makes the server download from HuggingFace and fail with HTTP 401"
    note "either set MODEL_ALIAS when starting it, or LLM_MODEL in .env"
    note "server reports: $(printf '%s' "$models_body" | tr -d '\n' | cut -c1-200)"
  fi
fi

# ── 2. Containers ─────────────────────────────────────────────────────────────

section "2. Gateway containers"

if ! docker info >/dev/null 2>&1; then
  fail "Docker daemon is not running"
  note "start Docker Desktop, then: make up"
else
  pass "Docker daemon is running"

  running=$(docker compose ps --services --filter status=running 2>/dev/null)

  for service in effort-guard platform; do
    if printf '%s' "$running" | grep -qx "$service"; then
      pass "$service is running"
    else
      fail "$service is not running"
      note "start it with: make up"
    fi
  done
fi

# ── 3. Gateway API ────────────────────────────────────────────────────────────

section "3. Gateway API ($GATEWAY_URL)"

gateway_body=$(curl -fsS -m 5 "$GATEWAY_URL/v1/models" 2>&1)

if [ $? -ne 0 ]; then
  fail "/v1/models not reachable"
  note "curl said: $(printf '%s' "$gateway_body" | head -1)"
else
  pass "/v1/models is reachable"

  if printf '%s' "$gateway_body" | grep -q -- "$GATEWAY_MODEL"; then
    pass "exposes '$GATEWAY_MODEL'"
  else
    fail "'$GATEWAY_MODEL' is not exposed"
    note "gateway reports: $(printf '%s' "$gateway_body" | tr -d '\n' | cut -c1-200)"
  fi
fi

# ── 4. Inference ──────────────────────────────────────────────────────────────
#
# Thinking is disabled on these probes to keep them fast; correctness of the
# reasoning path is covered by check 5.

section "4. Inference through the gateway"
note "first call after a model load can take minutes (cold prefill)"

chat=$(curl -sS -m "$REQ_TIMEOUT" -X POST "$GATEWAY_URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$GATEWAY_MODEL\",\"max_completion_tokens\":16,\"reasoning_effort\":\"none\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the word ready.\"}]}" 2>&1)

if printf '%s' "$chat" | grep -q '"content"'; then
  pass "/v1/chat/completions answers"
else
  fail "/v1/chat/completions failed"
  note "$(printf '%s' "$chat" | tr -d '\n' | cut -c1-300)"
fi

# This is the endpoint the CLI actually uses. A plain mlx-vlm server does not
# implement it -- translating it into chat completions is what the gateway is
# for, so this check is the one that matters for the coding harness.
responses=$(curl -sS -m "$REQ_TIMEOUT" -X POST "$GATEWAY_URL/v1/responses" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$GATEWAY_MODEL\",\"max_output_tokens\":16,\"reasoning\":{\"effort\":\"none\"},\"input\":\"Reply with the word ready.\"}" 2>&1)

if printf '%s' "$responses" | grep -q '"output"'; then
  pass "/v1/responses answers (this is what the CLI uses)"
else
  fail "/v1/responses failed"
  note "$(printf '%s' "$responses" | tr -d '\n' | cut -c1-300)"
fi

# ── 5. Effort guard ───────────────────────────────────────────────────────────

section "5. Effort guard"

guarded=$(curl -sS -m "$REQ_TIMEOUT" -o /dev/null -w '%{http_code}' \
  -X POST "$GATEWAY_URL/v1/responses" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$GATEWAY_MODEL\",\"max_output_tokens\":16,\"reasoning\":{\"effort\":\"high\"},\"input\":\"Reply with the word ready.\"}" 2>&1)

if [ "$guarded" = "200" ]; then
  pass "effort 'high' is accepted (clamped to medium on the way upstream)"
else
  fail "effort 'high' returned HTTP $guarded"
  note "the Qwen3.8 chat template only accepts xhigh, medium and low"
  note "check that LLM_URL still points at the guard: docker compose logs effort-guard"
fi

direct=$(curl -sS -m "$REQ_TIMEOUT" -o /dev/null -w '%{http_code}' \
  -X POST "$MODEL_URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL_ALIAS\",\"max_completion_tokens\":16,\"reasoning_effort\":\"high\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>&1)

if [ "$direct" = "200" ]; then
  warn "the model server accepts 'high' directly (HTTP 200)"
  note "the chat template of this build apparently allows it; the guard is"
  note "then redundant but harmless. You can bypass it via LLM_URL in .env."
else
  pass "bypassing the guard reproduces HTTP $direct, so the guard is doing work"
fi

# ── 6. CLI ────────────────────────────────────────────────────────────────────

section "6. wingman CLI"

if ! command -v wingman >/dev/null 2>&1; then
  fail "wingman is not on PATH"
  note "brew install adrianliechti/tap/wingman-cli"
else
  pass "installed at $(command -v wingman)"

  if [ "${WINGMAN_URL:-}" = "" ]; then
    warn "WINGMAN_URL is not set in this shell"
    note "source scripts/wingman-env.sh"
  elif [ "${WINGMAN_URL%/}" = "${GATEWAY_URL%/}" ]; then
    pass "WINGMAN_URL points at the gateway"
  else
    warn "WINGMAN_URL is '$WINGMAN_URL', expected '$GATEWAY_URL'"
  fi

  case "${WINGMAN_EFFORT:-}" in
    low | medium | xhigh | none) pass "WINGMAN_EFFORT='$WINGMAN_EFFORT' is supported by the template" ;;
    "") warn "WINGMAN_EFFORT is unset, so the CLI will resolve 'high'" ;;
    *) warn "WINGMAN_EFFORT='$WINGMAN_EFFORT' is not accepted upstream; the guard will rewrite it" ;;
  esac
fi

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n'

if [ "$failed" -eq 0 ]; then
  printf '%s%sAll checks passed.%s Run the agent with:  source scripts/wingman-env.sh && wingman\n' "$BOLD" "$GREEN" "$OFF"
  exit 0
fi

printf '%s%s%d check(s) failed.%s\n' "$BOLD" "$RED" "$failed" "$OFF"
exit 1
