# Run the wingman CLI against your Claude subscription instead of the gateway.
#
# Source this file, do not execute it:
#
#   source ~/src/wingman-stack/scripts/claude-subscription-env.sh
#   wingman --agent claude
#
# This mode drives the native Claude Code CLI over ACP and uses its stored
# login. It does not touch the gateway, the local model, or the Responses API.
# See doc/claude-subscription.md.
#
# All this script does is remove the variables that would divert Claude Code
# away from that login -- including the ones wingman itself sets when it runs
# Claude against the gateway (`wingman acp claude --backend wingman`). Leftovers
# from such a run in the same shell would silently redirect this one.
#
# Works in bash and zsh.

# Credentials and endpoint. ANTHROPIC_BASE_URL is the dangerous one: it does not
# show up in `claude auth status`, so a stale value fails or bills elsewhere
# with no visible sign of why.
unset ANTHROPIC_API_KEY
unset ANTHROPIC_AUTH_TOKEN
unset ANTHROPIC_BASE_URL

# Model name overrides, set by wingman's --backend wingman path.
unset ANTHROPIC_DEFAULT_HAIKU_MODEL
unset ANTHROPIC_DEFAULT_SONNET_MODEL
unset ANTHROPIC_DEFAULT_OPUS_MODEL
unset ANTHROPIC_DEFAULT_FABLE_MODEL
unset ANTHROPIC_MODEL
unset ANTHROPIC_SMALL_FAST_MODEL

# Session markers injected when a shell runs *inside* Claude Code. Inheriting
# them into a nested instance is asking for confusion.
unset CLAUDECODE
unset CLAUDE_CODE_ENTRYPOINT
unset CLAUDE_CODE_SESSION_ID
unset CLAUDE_CODE_CHILD_SESSION

# WINGMAN_* is deliberately left alone: `--agent claude` uses the native login
# regardless of it (verified -- the local model server sees no traffic), and
# keeping it lets `wingman` and `wingman --agent claude` coexist in one shell.

# ── Report ────────────────────────────────────────────────────────────────────

if ! command -v claude >/dev/null 2>&1 &&
   [ ! -x "$HOME/.local/bin/claude" ] &&
   [ ! -x "$HOME/.claude/local/claude" ]; then
  echo "claude: not found on PATH, in ~/.local/bin or ~/.claude/local" >&2
  echo "  install Claude Code, or set WINGMAN_CLAUDE_PATH to its binary" >&2
else
  _claude_status=$(claude auth status 2>/dev/null)

  case "$_claude_status" in
    *'"loggedIn": true'*)
      case "$_claude_status" in
        *apiKeySource*)
          echo "claude: logged in, but an API key from the environment is in use" >&2
          echo "  that bills the API instead of your subscription" >&2
          ;;
        *)
          _claude_sub=$(printf '%s' "$_claude_status" \
            | sed -n 's/.*"subscriptionType": *"\([^"]*\)".*/\1/p')
          echo "claude: subscription login active${_claude_sub:+ ($_claude_sub)}"
          ;;
      esac
      ;;
    *)
      echo "claude: not logged in -- run: claude auth login" >&2
      ;;
  esac

  unset _claude_status _claude_sub
fi
