# Backend: Qwen3.8-27B on MLX

The reference backend of this stack: Qwen3.8-27B (MLX 4bit) served by `mlx-vlm`
on Apple Silicon, set up by
[mlx-qwen38-apple-silicon](https://github.com/here-be-dragons-ai/mlx-qwen38-apple-silicon).

Two properties of this model and this harness will bite you. Both are
model-specific — they do not apply to a hosted backend — and neither is fixable
from the CLI.

## 1. `reasoning_effort` — handled, by the effort guard

Qwen3.8's `chat_template.jinja` accepts exactly three values while thinking is
on, and raises otherwise:

```jinja
{%- if enable_thinking is undefined or enable_thinking is true %}
    {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
    {%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
        {{- raise_exception('Unexpected reasoning effort ...') }}
```

`mlx-vlm` does not validate the value, it forwards it into
`apply_chat_template()`, so the exception comes back as **HTTP 500**. The values
`none`, `off`, `disabled`, `false` and `0` are fine — `mlx-vlm` turns those into
`enable_thinking=false`, which skips the branch entirely
(`mlx_vlm/server/request_normalization.py`).

Now the harness side. wingman-agent resolves its main chat loop to `high`
whenever no effort is pinned:

```go
// pkg/code/agent/agent.go, effortFor()
if requested == "" {
    if role == modelRolePlan && model.ClassOf(current) == model.ClassLarge {
        requested = "xhigh"
    } else {
        requested = "high"
    }
}
return clampEffortForModel(requested, m)
```

`clampEffortForModel` clamps against a per-model `Efforts` list from the
compiled-in catalog, which is empty for this model — so nothing clamps on the
client side. Wingman then forwards the value verbatim
(`normalizedReasoningEffort` in `pkg/provider/openai/util.go`).

Two layers deal with it:

- `scripts/wingman-env.sh` pins `WINGMAN_EFFORT=low` and
  `WINGMAN_EFFORT_PLAN=xhigh`. That covers the main chat loop and plan mode.
- `effort-guard` clamps whatever still gets through, rounding **down** so a
  request never gets more reasoning than it asked for:

  | in | out |
  |---|---|
  | `high` | `medium` |
  | `max` | `xhigh` |
  | `minimal` | `low` |
  | `low`, `medium`, `xhigh` | unchanged |
  | `none`, `off`, `disabled`, `false`, `0` | unchanged (disables thinking) |
  | anything else | field dropped, template default applies |

The guard is not redundant with the env vars, because they cannot cover
everything: there is no environment variable for the utility role, and subagent
efforts are chosen by the model at runtime and can be `high` or `max`.

`make test` runs its unit tests. To bypass it for a backend that accepts the
full range, set `LLM_URL` in `.env` to point straight at the model server.

## 2. Context window — not handled, plan around it

The CLI believes this model has **262,144 tokens** of context, because that is
what its catalog says. A 48 GB machine cannot deliver that:

| profile | `context_length` | with `KV_BITS=8` |
|---|---|---|
| `lean` | 32,768 | 65,536 |
| `balanced` | 49,152 | 98,304 |
| `roomy` (48 GB) | 65,536 | 131,072 |

There is no way to tell the CLI otherwise. `ContextWindowFor`
(`pkg/agent/config.go`) reads the compiled-in catalog and falls back to 400,000
for unknown ids; neither an environment variable nor `~/.wingman/config.json`
overrides it. So the agent will not compact in time on long sessions, and the
model server eventually dies with `[METAL] Insufficient Memory`.

What to do instead:

- Keep `KV_BITS=8` (the default in `.env.example`). It halves the KV cache from
  64 to 32 KiB per token and roughly doubles the usable context, for a modest
  quality cost.
- Run `make watchdog` in a third terminal. It restarts the server before memory
  fills up, and the SSD prefix cache makes the restart cheap — a 36k prompt
  measured 89,630 ms cold against 350 ms after a restart.
- Compact early rather than at the limit, and start a fresh session for a new
  task instead of carrying one conversation all day.

## Measured performance

From the server log of a real first agent turn on an M5 Pro / 48 GB, `roomy`,
speculative decoding on:

| | |
|---|---|
| Agent prompt (system + tool definitions) | ~9,900 tokens |
| Cold prefill | 21.6 s at 458 tok/s |
| Follow-up turn after a tool call | 0.67 s at 14,910 tok/s (`cached_tokens=9885`) |
| Decode | 30–36 tok/s |

So the first turn of a session costs about 20 seconds and every turn after it is
effectively instant on the prompt side. That prefix cache is a precondition for
using this as an agent backend, not an optimisation.
