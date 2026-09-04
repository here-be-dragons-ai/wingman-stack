# wingman-local

Configuration that puts [wingman](https://github.com/adrianliechti/wingman) in
front of a local **Qwen3.8-27B** (MLX 4bit, served by `mlx-vlm`) so the
[wingman-agent](https://github.com/adrianliechti/wingman-agent) coding CLI can
use it as its backend.

The gateway runs in Docker. The model server does not, and cannot: Docker on
macOS has no access to the Metal GPU, so Qwen runs natively on the host.

## Why a gateway is needed

wingman-agent talks the [OpenResponses](https://www.openresponses.org) dialect
— it posts to `/v1/responses`. `mlx-vlm` only implements
`/v1/chat/completions`. Pointing the CLI straight at port 8888 therefore fails
on every request. Translating between the two dialects is exactly what the
wingman platform does, which is what makes this stack work at all.

```
  wingman CLI                    ── /v1/responses ──┐
  (native, on the host)                             │
                                                    ▼
                                        ┌──────────────────────────┐
                                        │ wingman platform         │  127.0.0.1:4242
                                        │ ghcr.io/…/wingman-       │  (Docker)
                                        │ platform                 │
                                        │                          │
                                        │ responses ⇄ chat         │
                                        └────────────┬─────────────┘
                                                     │ /v1/chat/completions
                                                     ▼
                                        ┌──────────────────────────┐
                                        │ effort-guard             │  (Docker)
                                        │ clamps reasoning_effort  │
                                        └────────────┬─────────────┘
                                                     │ host.docker.internal:8888
                                                     ▼
                                        ┌──────────────────────────┐
                                        │ mlx-vlm + Qwen3.8-27B    │  127.0.0.1:8888
                                        │ ../m532/start-mlx_…sh    │  (native, Metal)
                                        └──────────────────────────┘
```

## Prerequisites

| | |
|---|---|
| Model server | [`m532`](../m532) set up and working (`./install-prereqs.sh`, `sudo ./set-iogpu-wired-limit.sh`) |
| Docker | Docker Desktop, running |
| CLI | `brew install adrianliechti/tap/wingman-cli` |

## Quick start

```sh
cp .env.example .env       # optional, every value has a working default

make model                 # terminal 1: starts Qwen natively, keeps running
make up                    # terminal 2: builds and starts the gateway
make doctor                # verifies the whole chain

source scripts/wingman-env.sh
wingman                    # in whatever project you want to work on
```

`make doctor` is the thing to trust. It checks the model server, the alias it
serves, both containers, `/v1/models` and `/v1/responses` through the gateway,
the effort guard, and the CLI environment — and tells you which hop is broken
instead of leaving you with a generic connection error.

## The model name chain

Three names refer to the same model, and they are not interchangeable:

| Where | Name | Set in |
|---|---|---|
| CLI asks wingman for | `qwen3.8-27b` | `WINGMAN_MODEL`, `scripts/wingman-env.sh` |
| wingman maps it to | `Qwen3.8-27B-local` | `LLM_MODEL`, `config/platform.yaml` |
| mlx-vlm loads | `Qwen3.8-27B-local` | `MODEL_ALIAS` of `start-mlx_qwen3.8.sh` |

The last two **must** match. With `mlx-vlm` the request model name *is* the
load path, so a mismatch makes the server discard the loaded model and start a
HuggingFace download, which surfaces as HTTP 401 on a model that is sitting
right there on disk.

The first one is deliberately different: `qwen3.8-27b` is a registered alias in
wingman-agent's compiled-in model catalog (`pkg/model/model.go`), so the CLI
resolves real metadata for it — class *medium*, 64k output — instead of falling
back to the 400,000-token default it uses for ids it does not recognise.

`client.yaml` describes the same contract in the format
`start-mlx_qwen3.8.sh` can cross-check; `make model` passes it as
`CLIENT_CONFIG`, so the start banner warns you when the two drift apart.

## Two things that will bite you

Both are properties of this model and this harness, not bugs in the setup.
Neither is fixable from the CLI, so read this section before wondering why
something failed.

### 1. `reasoning_effort` — handled, by the effort guard

Qwen3.8's `chat_template.jinja` accepts exactly three values while thinking is
on, and raises otherwise:

```jinja
{%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
{%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
    {{- raise_exception('Unexpected reasoning effort ...') }}
```

`mlx-vlm` does not validate the value, it forwards it into
`apply_chat_template()`, so the exception comes back as **HTTP 500**.
`none`, `off`, `disabled`, `false` and `0` are fine — `mlx-vlm` turns those
into `enable_thinking=false`, which skips the branch entirely.

wingman-agent resolves its main chat loop to `high` whenever no effort is
pinned (`effortFor` in `pkg/code/agent/agent.go`), and lets the model request
`high` or `max` per subagent. Its own clamping is driven by a per-model
`Efforts` list that is empty for this model, so nothing clamps client-side, and
wingman forwards the value verbatim (`normalizedReasoningEffort` in
`pkg/provider/openai/util.go`).

Two layers deal with it:

- `scripts/wingman-env.sh` pins `WINGMAN_EFFORT=low` and
  `WINGMAN_EFFORT_PLAN=xhigh`, which covers the main loop and plan mode.
- `effort-guard` clamps whatever still gets through, rounding down so a request
  never gets more reasoning than it asked for: `high → medium`, `max → xhigh`,
  `minimal → low`, unknown values are dropped so the template default applies.

The guard exists because the env vars cannot cover everything: there is no
variable for the utility role, and subagent efforts are chosen by the model at
runtime. `make test` runs its unit tests; set `LLM_URL` in `.env` to bypass it.

### 2. Context window — not handled, plan around it

The CLI believes this model has **262,144 tokens** of context, because that is
what its catalog says. Your machine cannot deliver that:

| profile | `context_length` | with `KV_BITS=8` |
|---|---|---|
| `lean` | 32,768 | 65,536 |
| `balanced` | 49,152 | 98,304 |
| `roomy` (48 GB) | 65,536 | 131,072 |

There is no way to tell the CLI otherwise — `ContextWindowFor` reads the
compiled-in catalog and falls back to 400,000, and neither an env var nor
`~/.wingman/config.json` overrides it. So the agent will not compact in time
on long sessions, and the model server eventually dies with
`[METAL] Insufficient Memory`.

What to do instead:

- Keep `KV_BITS=8` (the default in `.env.example`). It halves the KV cache from
  64 to 32 KiB per token and roughly doubles the usable context, for a modest
  quality cost.
- Run `make watchdog` in a third terminal. It restarts the server before memory
  fills up, and the SSD prefix cache makes the restart cheap — a 36k prompt
  measured 89,630 ms cold against 350 ms after a restart.
- Compact early rather than at the limit, and start a fresh session for a new
  task instead of carrying one conversation all day.

## Configuration

| File | Purpose |
|---|---|
| `compose.yaml` | the two gateway services, ports, health checks |
| `config/platform.yaml` | wingman platform config: the provider and the model mapping |
| `client.yaml` | the gateway↔mlx-vlm contract, cross-checked by the start script |
| `.env` | local overrides; every value has a default in `compose.yaml` |
| `scripts/wingman-env.sh` | the CLI environment, meant to be sourced |
| `effort-guard/` | the reasoning-effort proxy and its tests |

### Environment

`.env` (see `.env.example` for the annotated version):

| Variable | Default | Effect |
|---|---|---|
| `WINGMAN_PORT` | `4242` | host port of the gateway, bound to loopback |
| `LLM_UPSTREAM_URL` | `http://host.docker.internal:8888` | the native model server, seen from a container |
| `LLM_MODEL` | `Qwen3.8-27B-local` | must equal `MODEL_ALIAS` |
| `LLM_TOKEN` | `sk-local` | forwarded upstream; `mlx-vlm` ignores it |
| `LLM_URL` | *(unset)* | set it to bypass the effort guard |
| `LOG_REWRITES` | `1` | log every effort rewrite |
| `PROFILE`, `KV_BITS` | `roomy`, `8` | passed to `make model` |

CLI variables, set by `scripts/wingman-env.sh`:

| Variable | Value | Why |
|---|---|---|
| `WINGMAN_URL` | `http://localhost:4242` | **without** `/v1`; the CLI appends it. Takes priority over every `OPENAI_*` / `OLLAMA_*` variable, so a stray `OPENAI_API_KEY` cannot silently redirect the agent to a paid API |
| `WINGMAN_MODEL`, `…_PLAN`, `…_UTILITY` | `qwen3.8-27b` | one model serves all three roles |
| `WINGMAN_EFFORT` | `low` | `high` would be rejected upstream |
| `WINGMAN_EFFORT_PLAN` | `xhigh` | accepted, and plan mode is worth the tokens |

### Adding authentication

The gateway is published on `127.0.0.1` only and has no authorizer, so
anything on this machine can use it. To require a token, add to
`config/platform.yaml`:

```yaml
authorizers:
  - type: static
    token: ${WINGMAN_TOKEN}
```

Then set `WINGMAN_TOKEN` in `.env`, add it to the `platform` environment in
`compose.yaml`, and export the same value for the CLI. `oidc` (with `issuer`
and `audience`) and `header` are the other supported types.

## Using the CLI

```sh
source ~/src/wingman/scripts/wingman-env.sh

wingman                                  # TUI in the current directory
wingman --continue                       # resume the last session
wingman exec "Summarize this project"    # non-interactive
git diff | wingman exec "Review this"    # stdin becomes context
wingman server                           # web UI, same backend
```

`make agent` does the sourcing for you but runs in this repo's directory, which
is rarely what you want — source the file in your project shell instead.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `effort-guard: upstream unreachable` | model server not running, or not reachable at `LLM_UPSTREAM_URL`. See the note below. |
| HTTP 401, or a HuggingFace download starts | `LLM_MODEL` ≠ `MODEL_ALIAS` |
| HTTP 500 on every request | an effort the template rejects; check `docker compose logs effort-guard` |
| `404` on `/v1/responses` | the CLI is talking to `mlx-vlm` directly instead of the gateway; check `WINGMAN_URL` |
| `[METAL] Insufficient Memory` | context over budget — see *Two things that will bite you*, part 2 |
| The CLI picks a wrong or absent model | `curl localhost:4242/v1/models`; the name must match `WINGMAN_MODEL` |
| Answers stall for minutes on the first turn | cold prefill; 2–3 minutes for 30k tokens is normal, subsequent turns hit the prefix cache |

**On reaching the host from a container.** `start-mlx_qwen3.8.sh` binds
`127.0.0.1` on purpose. That is fine: Docker Desktop proxies
`host.docker.internal` from the host side, so a loopback-bound server stays
reachable — verified on this machine with Docker 29.7.2. Keep the default bind
address. Only if the guard reports `upstream unreachable` despite a running
server, fall back to `BIND_HOST=0.0.0.0`, and note that this exposes an
unauthenticated model server to your whole network.

## Files

| | |
|---|---|
| `compose.yaml` | gateway services |
| `config/platform.yaml` | wingman platform configuration |
| `client.yaml` | contract for the start script's `CLIENT_CONFIG` check |
| `effort-guard/main.go` | the proxy, with the full reasoning behind it in the header comment |
| `effort-guard/main_test.go` | mapping, JSON round-trip and middleware tests |
| `scripts/doctor.sh` | end-to-end verification |
| `scripts/wingman-env.sh` | CLI environment, source it |
| `Makefile` | `make help` lists everything |
