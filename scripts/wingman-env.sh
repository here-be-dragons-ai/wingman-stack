# Point the wingman CLI at the local gateway.
#
# Source this file, do not execute it:
#
#   source ~/src/wingman-stack/scripts/wingman-env.sh
#   wingman
#
# Override anything before sourcing:
#
#   WINGMAN_PORT=5000 source ~/src/wingman-stack/scripts/wingman-env.sh
#
# Works in bash and zsh. Requires wingman-cli 0.16.1 or newer.

: "${WINGMAN_PORT:=4242}"

# Without the /v1 suffix -- the CLI appends it. WINGMAN_URL takes priority over
# every OPENAI_*, OPENROUTER_* and OLLAMA_* variable, so a stray OPENAI_API_KEY
# in the shell cannot silently redirect the agent to a paid API.
export WINGMAN_URL="http://localhost:${WINGMAN_PORT}"

# The name config/platform.yaml exposes. Keep it a name the CLI's model catalog
# knows: the catalog is what supplies the supported reasoning efforts, and for
# an unrecognised id there is nothing to clamp against.
export WINGMAN_MODEL="qwen3.8-27b"
export WINGMAN_MODEL_PLAN="qwen3.8-27b"
export WINGMAN_MODEL_UTILITY="qwen3.8-27b"

# The real context budget of this machine, which the model catalog cannot know.
# Without it the CLI compacts against the catalog's 262144 and the model server
# dies with [METAL] Insufficient Memory partway through a session.
#
#   profile    plain    with KV_BITS=8
#   lean       32768    65536
#   balanced   49152    98304
#   roomy      65536    131072
#
# Default assumes roomy + KV_BITS=8, matching .env.example. Lower it to match
# your profile; the model server's start banner prints the authoritative budget.
: "${WINGMAN_CONTEXT_WINDOW:=131072}"
export WINGMAN_CONTEXT_WINDOW

# Qwen3.8 supports none, low, medium and xhigh -- the CLI clamps to that set
# from its catalog since 0.16.1, so these are a speed choice rather than a
# correctness requirement. Unset, the coding role resolves to medium; low keeps
# tool-heavy turns short, and plan mode is worth the extra tokens.
export WINGMAN_EFFORT="low"
export WINGMAN_EFFORT_PLAN="xhigh"

# The gateway has no authorizer configured; the CLI still wants a value.
export WINGMAN_TOKEN="${WINGMAN_TOKEN:--}"
