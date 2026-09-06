# Backend: Qwen3.8-27B on MLX

The reference backend of this stack: Qwen3.8-27B (MLX 4bit) served by `mlx-vlm`
on Apple Silicon, set up by
[mlx-qwen38-apple-silicon](https://github.com/here-be-dragons-ai/mlx-qwen38-apple-silicon).

This model constrains two things the agent would otherwise get wrong. Both are
handled as of **wingman-cli 0.16.1**, one of them only if you configure it. This
page records what the constraints are, so the configuration is not cargo cult.

> Requires wingman-cli 0.16.1 or newer. On 0.16.0 and earlier neither fix
> exists: pin the efforts by hand and run the stack with `make up-guard`.

## 1. `reasoning_effort` — fixed in the CLI

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

The problem was that the agent resolves its main chat loop to `high` whenever no
effort is pinned (`effortFor` in `pkg/code/agent/agent.go`), while its clamping
is driven by a per-model `Efforts` list that was empty for this model — so
nothing clamped, and wingman forwards the value verbatim
(`normalizedReasoningEffort` in `pkg/provider/openai/util.go`).

0.16.1 closes it in the model catalog:

```go
var qwen38Efforts = []string{"none", "low", "medium", "xhigh"}
```

With `effortValues = [auto, none, low, medium, high, xhigh, max]`,
`clampEffortForModel` now rounds down to the nearest supported level:
`high → medium`, `max → xhigh`. Nothing to configure — but it only works when
the model name resolves to that catalog entry, which is why
`scripts/wingman-env.sh` uses `qwen3.8-27b` rather than a private alias. See
[architecture.md](architecture.md#the-model-name-chain).

### The effort guard

`effort-guard` did this clamping in the gateway before the CLI could. It is
still in the repository but **off by default**, because it now duplicates work
the client already does. Enable it with `make up-guard` when:

- the CLI is older than 0.16.1,
- the model is exposed under a name the catalog does not recognise, so there is
  no `Efforts` list to clamp against, or
- something other than wingman-agent talks to the gateway.

It applies the same mapping, rounding down so a request never gets more
reasoning than it asked for:

| in | out |
|---|---|
| `high` | `medium` |
| `max` | `xhigh` |
| `minimal` | `low` |
| `low`, `medium`, `xhigh` | unchanged |
| `none`, `off`, `disabled`, `false`, `0` | unchanged (disables thinking) |
| `auto`, or anything else unrankable | `medium` |

The last row used to drop the field instead, which handed the request to the
template's own default — and that default is `xhigh`, the most expensive level,
for a request that never asked for it. `medium` keeps the round-down promise.

`make test` runs its unit tests.

## 2. Context window — you must set it

The model catalog says this model has **262,144 tokens** of context. That is
true of Qwen3.8 in general and false of any machine running it locally in 4-bit
with a finite KV cache. The CLI compacts against whatever number it believes, so
believing the catalog means never compacting in time.

This is not theoretical. It is what a real session did on an M5 Pro / 48 GB:

```
13:29:47 ERROR [METAL] Command buffer execution failed: Insufficient Memory
         mem active=32.62 cache=0.62 sum=33.25 GiB (83% of 40.00 GiB working set)
         peak=40.69 GiB
13:30:14 Shutting down
```

The agent kept growing the prompt because nothing told it not to, peak crossed
the 40 GiB working set, and the model server died mid-session.

0.16.1 adds the override:

```sh
export WINGMAN_CONTEXT_WINDOW=131072
```

It takes precedence over the catalog (`ContextWindowFor` in
`pkg/agent/config.go`), and `scripts/wingman-env.sh` exports it. Match it to the
profile you start the server with:

| profile | plain | with `KV_BITS=8` |
|---|---|---|
| `lean` | 32,768 | 65,536 |
| `balanced` | 49,152 | 98,304 |
| `roomy` (48 GB) | 65,536 | 131,072 |

The start banner prints a computed `CONTEXT BUDGET` for the running machine —
on `roomy` with `KV_BITS=8` it reports about 241,000 tokens. Treat that as the
upper bound it says it is, not a target: the profile's own recommendation is
65,536, and 131,072 sits deliberately between the two. The `mem` lines in the
server log are the authoritative signal.

Two habits still pay off, because a context limit reached cleanly is better than
one reached at all:

- Run `make watchdog` in a third terminal. It restarts the server before memory
  fills up, and the SSD prefix cache makes the restart cheap — a 36k prompt
  measured 89,630 ms cold against 350 ms after a restart.
- Start a fresh session per task instead of carrying one conversation all day.

## Measured performance

From the server log of real first agent turns on an M5 Pro / 48 GB, `roomy`,
speculative decoding on:

| | |
|---|---|
| Agent prompt (system + tool definitions) | ~9,900 tokens |
| Cold prefill | 21 s at 460–490 tok/s |
| Follow-up turn after a tool call | 0.67 s at 14,910 tok/s (`cached_tokens=9885`) |
| Decode | 25–36 tok/s |

So the first turn of a session costs about 20 seconds and every turn after it is
effectively instant on the prompt side. That prefix cache is a precondition for
using this as an agent backend, not an optimisation.
