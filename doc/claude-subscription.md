# Using your Claude subscription

wingman-agent can drive the **native Claude Code CLI** and use its stored login,
so a Claude Pro, Max or Team subscription becomes the backend instead of a
model server.

This mode bypasses everything else in this repository. No gateway, no local
model, no Responses API translation:

```
  wingman --agent claude
        │
        │ ACP over stdio
        ▼
  claude  (native CLI, its own login and session storage)
        │
        ▼
  Anthropic, billed to your subscription
```

It is worth having next to the local setup for the obvious reason: the same
terminal UI, the same skills and MCP servers, and you pick per task whether it
runs on hardware you control or on a frontier model.

## Setup

```sh
claude auth login          # once, if not already signed in
claude auth status         # "loggedIn": true, no "apiKeySource"

source /path/to/wingman-stack/scripts/claude-subscription-env.sh
wingman --agent claude
```

The script does one thing: it removes the environment variables that would
divert Claude Code away from your subscription, then prints what it found:

```
claude: subscription login active (team)
```

Requires the `claude` binary. wingman looks for it on `PATH`, then
`~/.local/bin/claude`, then `~/.claude/local/claude`; `WINGMAN_CLAUDE_PATH`
overrides the search.

## Usage

```sh
wingman --agent claude                     # TUI
wingman --agent claude --continue          # resume the latest native session
wingman exec --agent claude "…" </dev/null # non-interactive
wingman acp claude                         # ACP stdio, native backend
```

Sessions are stored by Claude Code, not by wingman, so `--continue` resumes the
native session history.

## What can divert it

`--agent claude` passes your shell environment to Claude Code **unchanged**
(`opts.Env = os.Environ()` in `cmd/wingman/acp.go`), and Claude Code reads the
standard `ANTHROPIC_*` variables. So anything left in the shell wins over the
subscription.

The trap is that wingman sets exactly those variables itself in its *other*
Claude mode, `wingman acp claude --backend wingman`, to point Claude Code at the
gateway (`pkg/external/claude/claude.go`):

| Variable | Set to | Effect if left over |
|---|---|---|
| `ANTHROPIC_BASE_URL` | the wingman gateway | requests leave for the gateway; **invisible in `claude auth status`** |
| `ANTHROPIC_AUTH_TOKEN` | `WINGMAN_TOKEN` | wrong credentials |
| `ANTHROPIC_API_KEY` | `""` | — |
| `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS,FABLE}_MODEL` | gateway model ids | model names that do not exist upstream |

`ANTHROPIC_BASE_URL` is the one to watch: `claude auth status` still reports
`"loggedIn": true` with it set, so there is no signal that requests are going
somewhere else. That is why the script unsets it rather than only checking.

An `ANTHROPIC_API_KEY` *is* visible — it shows up as
`"apiKeySource": "ANTHROPIC_API_KEY"` and blanks out `email`. A key from a
Claude Code settings file rather than the environment shows up the same way, and
the script warns about it, because it means the API is billed instead of the
subscription.

**`WINGMAN_*` variables do not interfere.** Verified: with
`WINGMAN_URL=http://localhost:4242` exported and the local model server running,
`wingman --agent claude` answered as Claude Opus 5 and the model server's
generation counter did not move. They only configure wingman's own built-in
agent, so `wingman` and `wingman --agent claude` can share one shell.

## Running it from inside Claude Code

A shell started by Claude Code carries `CLAUDECODE=1`,
`CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT` and friends. Launching a
nested instance with those inherited is a bad idea; the script unsets them.
Prefer a plain terminal anyway.

## The three Claude-related modes

Easy to mix up, so plainly:

| Command | Who answers | Billed to |
|---|---|---|
| `wingman` | wingman's built-in agent via the gateway | your model backend |
| `wingman --agent claude` | native Claude Code, its own login | your Claude subscription |
| `wingman acp claude --backend wingman` | Claude Code's UI, pointed at the gateway | your model backend |

The third exists to run the Claude Code front end against a local model. It is
the opposite of this page, and the reason the cleanup script is needed.
