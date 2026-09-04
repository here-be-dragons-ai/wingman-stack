# Point the wingman CLI at the local gateway.
#
# Source this file, do not execute it:
#
#   source ~/src/wingman/scripts/wingman-env.sh
#   wingman
#
# Override the port before sourcing if the gateway is published elsewhere:
#
#   WINGMAN_PORT=5000 source ~/src/wingman/scripts/wingman-env.sh
#
# Works in bash and zsh.

: "${WINGMAN_PORT:=4242}"

# Without the /v1 suffix -- the CLI appends it. WINGMAN_URL takes priority over
# every OPENAI_*, OPENROUTER_* and OLLAMA_* variable, so a stray OPENAI_API_KEY
# in the shell cannot silently redirect the agent to a paid API.
export WINGMAN_URL="http://localhost:${WINGMAN_PORT}"

# The name config/platform.yaml exposes. It matches an alias in the CLI's model
# catalog, so the TUI shows real metadata instead of guessing from the id.
export WINGMAN_MODEL="qwen3.8-27b"
export WINGMAN_MODEL_PLAN="qwen3.8-27b"
export WINGMAN_MODEL_UTILITY="qwen3.8-27b"

# The Qwen3.8 chat template accepts xhigh, medium and low only. Leaving these
# unset makes the CLI resolve "high", which the template rejects with HTTP 500.
# The effort guard clamps it as a backstop, but pinning the values here keeps
# the request honest and avoids a needless rewrite on every turn.
export WINGMAN_EFFORT="low"
export WINGMAN_EFFORT_PLAN="xhigh"

# The gateway has no authorizer configured; the CLI still wants a value.
export WINGMAN_TOKEN="${WINGMAN_TOKEN:--}"
