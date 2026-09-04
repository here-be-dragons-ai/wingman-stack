# wingman-stack

A ready-to-run [wingman](https://github.com/adrianliechti/wingman) gateway, so
that the [wingman-agent](https://github.com/adrianliechti/wingman-agent) coding
CLI can work against the model backend of your choice — local or hosted.

Wingman is the piece that makes this work. It puts one OpenAI-, Anthropic- and
Gemini-compatible API in front of many providers, and it speaks the Responses
API that the coding CLI needs but most local model servers do not implement.
This repository is the configuration around it: Docker Compose, a provider
config, a health check that tests the whole chain, and the environment the CLI
expects.

```
  wingman-agent  ──/v1/responses──▶  wingman platform  ──▶  model backend
      (CLI)                           (Docker, :4242)        (local or hosted)
```

The reference backend is a local **Qwen3.8-27B** (MLX 4bit) on Apple Silicon,
set up by
[mlx-qwen38-apple-silicon](https://github.com/here-be-dragons-ai/mlx-qwen38-apple-silicon).
Any other wingman provider works the same way — see
[doc/configuration.md](doc/configuration.md).

## Requirements

| | |
|---|---|
| Docker | Docker Desktop or a compatible engine, running |
| CLI | `brew install adrianliechti/tap/wingman-cli` — other install options in the [wingman-agent README](https://github.com/adrianliechti/wingman-agent#-installation) |
| A model backend | either an API key for a hosted provider, or a local server such as [mlx-qwen38-apple-silicon](https://github.com/here-be-dragons-ai/mlx-qwen38-apple-silicon), [Ollama](https://ollama.com) or `llama.cpp` |

## Install

```sh
git clone https://github.com/here-be-dragons-ai/wingman-stack.git
cd wingman-stack

cp .env.example .env    # optional, every value has a working default
make up                 # builds and starts the gateway
make doctor             # verifies the whole chain
```

With the MLX backend, start the model server first — `make model` runs it in the
foreground and keeps it there, so use a second terminal for the gateway:

```sh
make model              # terminal 1: the model server
make up                 # terminal 2: the gateway
make doctor             # terminal 2: verify
```

`make doctor` is the thing to trust. It reports each hop separately, so a
failure tells you *where* the chain is broken.

## Use

```sh
source /path/to/wingman-stack/scripts/wingman-env.sh
cd ~/your-project
wingman
```

The `source` sets `WINGMAN_URL`, the model and the reasoning efforts for the
current shell; run it again in a new terminal.

```sh
wingman                                       # TUI in the current directory
wingman --continue                            # resume the last session
wingman exec "Summarize this project" </dev/null   # non-interactive
git diff | wingman exec "Review this"         # stdin becomes context
wingman server                                # web UI, same backend
```

The `</dev/null` is not decorative — see
[doc/troubleshooting.md](doc/troubleshooting.md#wingman-exec-and-stdin).

## What is in here

| | |
|---|---|
| `compose.yaml` | the gateway services |
| `config/platform.yaml` | wingman platform configuration: provider and model mapping |
| `client.yaml` | the gateway↔model-server contract, cross-checked by the MLX start script |
| `effort-guard/` | a small proxy that keeps reasoning efforts inside what the backend accepts |
| `scripts/doctor.sh` | end-to-end verification |
| `scripts/wingman-env.sh` | the CLI environment, source it |
| `Makefile` | `make help` lists every target |

## Documentation

| | |
|---|---|
| [doc/architecture.md](doc/architecture.md) | how the pieces fit, why the gateway is needed, the model name chain, ports |
| [doc/configuration.md](doc/configuration.md) | every file and variable, how to point the stack at another backend, authentication |
| [doc/qwen38-mlx.md](doc/qwen38-mlx.md) | the Qwen3.8/MLX backend: its two constraints, and measured performance |
| [doc/troubleshooting.md](doc/troubleshooting.md) | symptoms and their causes, useful commands |

## Credits

The substantial work is upstream, by
[Adrian Liechti](https://github.com/adrianliechti):

| Project | What it does | License |
|---|---|---|
| [wingman](https://github.com/adrianliechti/wingman) | the inference hub this repository configures — one API in front of many providers, and the Responses ⇄ chat translation the CLI depends on | [MIT](https://github.com/adrianliechti/wingman/blob/main/LICENSE), © 2023 Adrian Liechti |
| [wingman-agent](https://github.com/adrianliechti/wingman-agent) | the terminal coding agent | [MIT](https://github.com/adrianliechti/wingman-agent/blob/main/LICENSE), © 2026 Adrian Liechti |

Without them there is nothing here to configure. If this stack is useful to
you, the credit belongs to those two projects.

## License

This repository holds configuration and one small proxy. It is licensed under
[MIT No Attribution](LICENSE) (SPDX: `MIT-0`) — copy, adapt and reuse without
attribution.

It contains **no** wingman or wingman-agent source code. The platform is pulled
as the published `ghcr.io/adrianliechti/wingman-platform` image and the CLI is
installed separately, so both remain under their own MIT license and notices,
which the table above links. MIT-0 applies only to the files in this
repository.
