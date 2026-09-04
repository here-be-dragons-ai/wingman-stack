# Architecture

## Why a gateway is needed at all

wingman-agent talks the [OpenResponses](https://www.openresponses.org) dialect —
it posts to `/v1/responses`. Most local model servers, `mlx-vlm` among them,
only implement `/v1/chat/completions`. Pointing the CLI straight at the model
server therefore fails on every single request with a 404.

Translating between the two dialects is what the
[wingman platform](https://github.com/adrianliechti/wingman) does. That
translation is the reason this stack exists; everything else in this repository
is configuration around it.

## The request path

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
                                        │ clamps reasoning_effort  │  optional
                                        └────────────┬─────────────┘
                                                     │ host.docker.internal:8888
                                                     ▼
                                        ┌──────────────────────────┐
                                        │ mlx-vlm + Qwen3.8-27B    │  127.0.0.1:8888
                                        │ (native, Metal)          │
                                        └──────────────────────────┘
```

The model server runs natively rather than in a container, and with the MLX
backend it has to: Docker on macOS has no access to the Metal GPU. The
containers reach it through `host.docker.internal`.

`effort-guard` is specific to the Qwen3.8 chat template — see
[qwen38-mlx.md](qwen38-mlx.md). For a backend that accepts the full range of
reasoning efforts, point `LLM_URL` past it.

## Reaching the host from a container

The MLX start script binds `127.0.0.1` on purpose, and that is fine: Docker
Desktop proxies `host.docker.internal` from the host side, so a loopback-bound
server stays reachable. Verified with Docker 29.7.2 on macOS 26.

Keep the default bind address. Only if the guard reports `upstream unreachable`
despite a running server, fall back to `BIND_HOST=0.0.0.0` — and note that this
exposes an unauthenticated model server to your whole network.

## The model name chain

Three names refer to the same model, and they are not interchangeable:

| Where | Name | Set in |
|---|---|---|
| CLI asks wingman for | `qwen3.8-27b` | `WINGMAN_MODEL`, `scripts/wingman-env.sh` |
| wingman maps it to | `Qwen3.8-27B-local` | `LLM_MODEL`, `config/platform.yaml` |
| mlx-vlm loads | `Qwen3.8-27B-local` | `MODEL_ALIAS` of the start script |

The last two **must** match. With `mlx-vlm` the request model name *is* the load
path, so a mismatch makes the server discard the loaded model and start a
HuggingFace download — which surfaces as HTTP 401 on a model that is sitting
right there on disk.

The first one is deliberately different. `qwen3.8-27b` is a registered alias in
wingman-agent's compiled-in model catalog (`pkg/model/model.go`), so the CLI
resolves real metadata for it — class *medium*, 64k output — instead of falling
back to the 400,000-token default it uses for ids it does not recognise.

`client.yaml` describes the same contract in the format the MLX start script can
cross-check. `make model` passes it as `CLIENT_CONFIG`, so the start banner warns
you when the two drift apart.

## Ports

| Port | Bound to | What |
|---|---|---|
| 4242 | `127.0.0.1` | wingman platform, the gateway the CLI talks to |
| 8080 | container-internal | both the platform and the effort guard inside their containers |
| 8888 | `127.0.0.1` | the native model server |

4242 is also the port the wingman CLI falls back to when no backend variable is
set at all, which is why it is the default here.
