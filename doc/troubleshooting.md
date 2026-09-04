# Troubleshooting

Start with `make doctor`. It checks the model server, the alias it serves, both
containers, `/v1/models` and `/v1/responses` through the gateway, the effort
guard and the CLI environment — and names the hop that is broken instead of
leaving you with a generic connection error.

## Symptoms

| Symptom | Cause |
|---|---|
| `effort-guard: upstream unreachable` | model server not running, or not reachable at `LLM_UPSTREAM_URL` |
| HTTP 401, or a HuggingFace download starts | `LLM_MODEL` ≠ `MODEL_ALIAS`, see [architecture.md](architecture.md#the-model-name-chain) |
| HTTP 500 on every request | an effort the chat template rejects; check `docker compose logs effort-guard` |
| `404` on `/v1/responses` | the CLI is talking to the model server directly instead of the gateway; check `WINGMAN_URL` |
| `[METAL] Insufficient Memory` | context over budget, see [qwen38-mlx.md](qwen38-mlx.md#2-context-window--not-handled-plan-around-it) |
| The CLI picks a wrong or absent model | `curl localhost:4242/v1/models`; the name must match `WINGMAN_MODEL` |
| Answers stall for ~20 s on the first turn | cold prefill of the agent prompt; the next turn hits the prefix cache |
| `wingman exec` hangs with no output at all | it is reading stdin as context. In a script or non-interactive shell: `wingman exec "…" < /dev/null` |

## `wingman exec` and stdin

`wingman exec` treats piped stdin as context, which is a feature — this is how
you get a diff reviewed:

```sh
git diff | wingman exec "Review this for bugs"
```

The trap is that in a script, a CI job or any shell where stdin is an open pipe
that never closes, `exec` waits for input that never arrives. It produces no
output and burns no CPU, so it looks exactly like a hung model server. Redirect
stdin when you do not mean to pipe anything:

```sh
wingman exec "Summarize this project" < /dev/null
```

The interactive TUI (`wingman`) is unaffected.

## Useful commands

```sh
make doctor                             # verify the whole chain
make logs                               # follow gateway logs
docker compose logs effort-guard        # see which efforts got rewritten

curl localhost:4242/v1/models           # what the gateway exposes
curl localhost:8888/v1/models           # what the model server exposes

# Model server diagnostics (MLX backend)
rg "Prefill completed" ~/.mlx-qwen38/logs/server.log | tail -5   # cache hitting?
rg "mem active" ~/.mlx-qwen38/logs/server.log | tail -20         # memory over time
```

On a laptop, put `caffeinate -dimsu` in front of long agent runs — on battery
the Mac falls asleep mid-generation, and the log then reports plausible elapsed
times while the wall clock jumps by minutes. `make model` already does this.
