# Configuration

## Files

| File | Purpose |
|---|---|
| `compose.yaml` | the gateway services, ports, health checks |
| `config/platform.yaml` | wingman platform config: the provider and the model mapping |
| `client.yaml` | the gateway↔model-server contract, cross-checked by the MLX start script |
| `.env` | local overrides; every value has a default in `compose.yaml` |
| `scripts/wingman-env.sh` | the CLI environment, meant to be sourced |
| `effort-guard/` | the reasoning-effort proxy and its tests |

## Environment

`.env`, see `.env.example` for the annotated version:

| Variable | Default | Effect |
|---|---|---|
| `WINGMAN_PORT` | `4242` | host port of the gateway, bound to loopback |
| `LLM_UPSTREAM_URL` | `http://host.docker.internal:8888` | the model server, as seen from inside a container |
| `LLM_MODEL` | `Qwen3.8-27B-local` | the id the upstream expects; must equal `MODEL_ALIAS` |
| `LLM_TOKEN` | `sk-local` | forwarded upstream; `mlx-vlm` ignores it |
| `LLM_URL` | *(unset)* | set it to bypass the effort guard |
| `LOG_REWRITES` | `1` | log every effort rewrite |
| `PROFILE`, `KV_BITS` | `roomy`, `8` | passed through to `make model` |

CLI variables, set by `scripts/wingman-env.sh`:

| Variable | Value | Why |
|---|---|---|
| `WINGMAN_URL` | `http://localhost:4242` | **without** `/v1`; the CLI appends it. Takes priority over every `OPENAI_*`, `OPENROUTER_*` and `OLLAMA_*` variable, so a stray `OPENAI_API_KEY` cannot silently redirect the agent to a paid API |
| `WINGMAN_MODEL`, `…_PLAN`, `…_UTILITY` | `qwen3.8-27b` | one model serves all three roles |
| `WINGMAN_EFFORT` | `low` | see [qwen38-mlx.md](qwen38-mlx.md) |
| `WINGMAN_EFFORT_PLAN` | `xhigh` | accepted by the template, and plan mode is worth the tokens |

## Using a different backend

`config/platform.yaml` holds a single wingman provider. Wingman supports many
more — `openai`, `anthropic`, `gemini`, `bedrock`, `mistral`, `openrouter`,
`xai`, `ollama`, `llama` and the generic `openai-compatible` used here. The
[wingman README](https://github.com/adrianliechti/wingman) is the reference for
the full set.

To point the stack somewhere else, replace the provider block. For a hosted
OpenAI-compatible endpoint:

```yaml
providers:
  - type: openai-compatible
    url: https://api.example.com/v1
    token: ${LLM_TOKEN}

    models:
      my-model:
        id: upstream-model-id
```

Two things to keep in mind:

- The map key is the name the CLI asks for, so it has to match `WINGMAN_MODEL`.
  Prefer a name from wingman-agent's model catalog; unknown ids get a
  400,000-token context assumption.
- `effort-guard` clamps reasoning efforts to what the *Qwen3.8* template
  accepts. For a backend where `high` is valid, set `LLM_URL` in `.env` to point
  past the guard.

Several models can be listed under one provider, and several providers can
coexist — then `WINGMAN_MODEL`, `WINGMAN_MODEL_PLAN` and `WINGMAN_MODEL_UTILITY`
can name different models and the CLI will use each for its role.

## Adding authentication

The gateway is published on `127.0.0.1` only and has no authorizer, so anything
on this machine can use it. To require a token, add to `config/platform.yaml`:

```yaml
authorizers:
  - type: static
    token: ${WINGMAN_TOKEN}
```

Then set `WINGMAN_TOKEN` in `.env`, add it to the `platform` environment in
`compose.yaml`, and export the same value for the CLI. `oidc` (with `issuer` and
`audience`) and `header` are the other supported types.
