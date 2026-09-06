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

# The model server as seen from the host. LLM_UPSTREAM_URL is the *container's*
# view of it, so only the port carries over -- host.docker.internal does not
# resolve out here. Without this, changing the port in .env leaves this check
# probing 8888 and calling a healthy server unreachable.
upstream_port=$(printf '%s' "${LLM_UPSTREAM_URL:-}" \
  | sed -n 's|^\([a-zA-Z][a-zA-Z0-9+.-]*://\)\{0,1\}[^/]*:\([0-9][0-9]*\).*|\2|p')

MODEL_URL="${MODEL_URL:-http://localhost:${upstream_port:-8888}}"
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

  running=$(docker compose --profile guard ps --services --filter status=running 2>/dev/null)

  if printf '%s' "$running" | grep -qx "platform"; then
    pass "platform is running"
  else
    fail "platform is not running"
    note "start it with: make up"
  fi

  # The guard is optional since wingman-agent 0.16.1 clamps efforts itself.
  if printf '%s' "$running" | grep -qx "effort-guard"; then
    guard_running=1
    pass "effort-guard is running (optional backstop)"
  else
    pass "effort-guard is not running (optional; the CLI clamps efforts itself)"
    note "enable it with: make up-guard"
  fi
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

section "5. Reasoning effort"

# Qwen3.8's chat template accepts none, low, medium and xhigh only. Who enforces
# that depends on the setup: with the guard in the path it is enforced here,
# otherwise the CLI clamps client-side from its model catalog (0.16.1+).

probe_code=''
probe_error=''
probe_body=''

# probe_effort EFFORT -- sets $probe_code to the HTTP status of a /v1/responses
# call at that effort, $probe_body to the response payload, and $probe_error to
# whatever curl itself complained about. The three must stay on separate
# streams: merged, an unreachable gateway produces a string that matches no
# status we test for, and the "not 200" branch below would report a dead
# gateway as an expected rejection.
probe_effort() {
  local stderr body
  stderr=$(mktemp)
  body=$(mktemp)

  probe_code=$(curl -sS -m "$REQ_TIMEOUT" -o "$body" -w '%{http_code}' \
    -X POST "$GATEWAY_URL/v1/responses" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$GATEWAY_MODEL\",\"max_output_tokens\":16,\"reasoning\":{\"effort\":\"$1\"},\"input\":\"Reply with the word ready.\"}" \
    2>"$stderr")

  probe_error=$(tr -d '\n' < "$stderr" | cut -c1-200)
  probe_body=$(tr -d '\n' < "$body" | cut -c1-300)
  rm -f "$stderr" "$body"
}

# rejected_the_effort BODY -- true when BODY is the chat template refusing the
# effort rather than some unrelated failure at a similar status.
#
# The status code alone cannot carry this. A model server that is simply down
# also produces a non-200 ("dial tcp ...: connection refused", HTTP 400 through
# the gateway), and reading that as the expected rejection reports a broken
# chain as a green check. The template raises "Unexpected reasoning effort ...";
# matching the two words is enough, and cannot collide with a gateway that
# echoes the request, since that renders as reasoning":{"effort.
rejected_the_effort() {
  printf '%s' "$1" | grep -qi 'reasoning effort'
}

# curl reports 000 when it never got a response at all.
probe_effort xhigh

if [ "$probe_code" = "200" ]; then
  pass "a supported effort ('xhigh') is accepted"
elif [ "$probe_code" = "000" ]; then
  fail "the 'xhigh' probe never reached the gateway"
  note "${probe_error:-curl could not complete the request}"
else
  fail "a supported effort ('xhigh') returned HTTP $probe_code"

  if [ -n "$probe_body" ]; then note "$probe_body"; fi
  if [ -n "$probe_error" ]; then note "$probe_error"; fi
fi

probe_effort high
unsupported="$probe_code"
unsupported_error="$probe_error"
unsupported_body="$probe_body"

if [ "$unsupported" = "000" ]; then
  # No response at all says nothing about effort handling in either direction.
  fail "the 'high' probe never reached the gateway"
  note "${unsupported_error:-curl could not complete the request}"
elif [ "${guard_running:-0}" = "1" ]; then
  if [ "$unsupported" = "200" ]; then
    pass "the guard clamps 'high' (accepted, sent upstream as medium)"
  else
    fail "with the guard running, 'high' returned HTTP $unsupported"
    note "check that LLM_URL points at the guard: docker compose logs effort-guard"
    if [ -n "$unsupported_body" ]; then note "$unsupported_body"; fi
  fi
elif [ "$unsupported" = "200" ]; then
  warn "'high' was accepted upstream without the guard"
  note "this model build apparently tolerates it; nothing to do"
elif rejected_the_effort "$unsupported_body"; then
  pass "'high' is rejected upstream (HTTP $unsupported), as expected"
  note "unsupported efforts are the client's job here: wingman-cli 0.16.1+"
  note "clamps them from its catalog, which is why the guard is off by default."
  note "Another client on the gateway, or an unrecognised model name? It has"
  note "no catalog to clamp against -- run: make up-guard"
else
  # Non-200, but not the template refusing the effort -- so this proves nothing
  # about effort handling. Usually the same breakage section 4 just reported.
  fail "'high' returned HTTP $unsupported, but not because the effort was rejected"
  note "this says nothing about effort handling; fix the hop above first"
  if [ -n "$unsupported_body" ]; then note "$unsupported_body"; fi
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
    "") warn "WINGMAN_EFFORT is unset; the CLI resolves 'high' and clamps it to medium" ;;
    *) warn "WINGMAN_EFFORT='$WINGMAN_EFFORT' is not accepted upstream; it will be clamped" ;;
  esac

  # The one setting the model catalog cannot supply. Getting it wrong does not
  # fail a request -- it kills the model server later in the session.
  if [ -z "${WINGMAN_CONTEXT_WINDOW:-}" ]; then
    fail "WINGMAN_CONTEXT_WINDOW is not set"
    note "the CLI would compact against the catalog's 262144, which no profile"
    note "on this machine can deliver: expect [METAL] Insufficient Memory."
    note "source scripts/wingman-env.sh, or upgrade to wingman-cli 0.16.1+"
  elif [ "$WINGMAN_CONTEXT_WINDOW" -gt 0 ] 2>/dev/null; then
    pass "WINGMAN_CONTEXT_WINDOW=$WINGMAN_CONTEXT_WINDOW"
  else
    fail "WINGMAN_CONTEXT_WINDOW='$WINGMAN_CONTEXT_WINDOW' is not a positive number"
    note "a value the CLI cannot parse is ignored, falling back to the catalog"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n'

if [ "$failed" -eq 0 ]; then
  printf '%s%sAll checks passed.%s Run the agent with:  source scripts/wingman-env.sh && wingman\n' "$BOLD" "$GREEN" "$OFF"
  exit 0
fi

printf '%s%s%d check(s) failed.%s\n' "$BOLD" "$RED" "$failed" "$OFF"
exit 1
