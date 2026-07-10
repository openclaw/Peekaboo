---
title: AI providers
summary: 'Configure model providers and credentials for the Peekaboo agent runtime.'
description: Configure OpenAI, Anthropic Claude, xAI Grok, Google Gemini, MiniMax, Kimi, OpenRouter, and local providers for the Peekaboo agent.
read_when:
  - 'configuring model credentials or provider selection'
  - 'debugging agent model, tool-calling, or local Ollama setup'
---

# AI providers

Peekaboo's agent runtime is provider-agnostic — it talks to any chat-completions-style backend through Tachikoma. You configure provider credentials once and pick a model per-run.

## Supported providers

This table is the central reference for user-facing provider docs. Link here from architecture, install, and README
pages instead of duplicating provider lists in multiple places.

| Provider | Example model IDs | Credential |
| --- | --- | --- |
| **OpenAI** | gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5, gpt-5-mini, gpt-4.1 | `OPENAI_API_KEY` |
| **Anthropic** | claude-fable-5, claude-sonnet-5, claude-opus-4-8, claude-sonnet-4-6, claude-haiku-4-5 | `ANTHROPIC_API_KEY` |
| **xAI** | grok-4 | `XAI_API_KEY` |
| **Google** | gemini-3.1-pro-preview, gemini-3-flash | `GEMINI_API_KEY` |
| **MiniMax** | MiniMax-M3, MiniMax-M2.7, MiniMax-M2.7-highspeed | `MINIMAX_API_KEY` |
| **MiniMax China** | MiniMax-M3, MiniMax-M2.7, MiniMax-M2.7-highspeed | `MINIMAX_CN_API_KEY` or `MINIMAX_API_KEY` |
| **Kimi** | kimi-k2.6, kimi-k2.7-code, kimi-k2.7-code-highspeed | `MOONSHOT_API_KEY` or `KIMI_API_KEY` |
| **OpenRouter** | any tool-calling OpenRouter model ID | `OPENROUTER_API_KEY` |
| **Ollama** | any local model with tool-calling | runs at `http://localhost:11434` |
| **LM Studio** | any local OpenAI-compatible model with tool-calling | runs at `http://localhost:1234/v1` |

Other Tachikoma-supported providers also work — see the [Tachikoma docs](https://github.com/steipete/Tachikoma) for the full list.

## Credentials

Credentials live in `~/.peekaboo/credentials`, encrypted at rest with the macOS Keychain when available. Set them once via the CLI:

```bash
peekaboo config set-credential OPENAI_API_KEY <key>
peekaboo config set-credential ANTHROPIC_API_KEY <key>
peekaboo config set-credential GEMINI_API_KEY <key>
peekaboo config set-credential MINIMAX_API_KEY <key>
peekaboo config set-credential MINIMAX_CN_API_KEY <key>
peekaboo config set-credential MOONSHOT_API_KEY <key>
peekaboo config set-credential OPENROUTER_API_KEY <key>
```

Environment variables override the stored values, which is handy in CI:

```bash
OPENAI_API_KEY=sk-... peekaboo agent "open a browser"
```

See [configuration.md](configuration.md) for the full precedence table.

## Picking a model

```bash
peekaboo agent --model gpt-5.6 "summarize this window"
peekaboo agent --model gpt-5.6-terra "summarize this window"
peekaboo agent --model claude-fable-5 "summarize this window"
peekaboo agent --model claude-sonnet-5 "summarize this window"
peekaboo agent --model claude-opus-4-8 "summarize this window"
peekaboo agent --model gemini-3-flash "summarize this window"
peekaboo agent --model minimax/MiniMax-M3 "summarize this window"
peekaboo agent --model minimax-cn/MiniMax-M3 "summarize this window"
peekaboo agent --model kimi/kimi-k2.7-code "summarize this window"
peekaboo agent --model openrouter/xiaomi/mimo-v2.5-pro "summarize this window"
peekaboo agent --model gpt-5-mini "click Continue and wait for the dialog"
peekaboo agent --model ollama/llama3.1:8b "describe this screenshot"
peekaboo agent --model lmstudio/openai/gpt-oss-120b "summarize this window"
```

Defaults come from `agent.defaultModel` in `~/.peekaboo/config.json`. Anthropic defaults stay on Opus 4.8 for zero-retention compatibility; select Fable 5 or Sonnet 5 explicitly when your Anthropic organization allows it. Set a per-project default with `PEEKABOO_AGENT_MODEL`.

The app and CLI share `agent.temperature` and `agent.maxTokens`. Peekaboo clamps those requests to provider
capabilities; Peekaboo currently catalogs Fable 5 and Sonnet 5 with 1M context windows and up to 128K output. See
[configuration.md](configuration.md#agent-generation-settings).

## Tool calling

The agent requires a tool-calling capable model. If the selected model does not support tools, Peekaboo rejects it and points to `peekaboo image --analyze` / `see --analyze` for vision-only use. Choose a tool-capable model for agent runs.

## Local-only mode

Want everything on-device? Run an Ollama model with tool calling and point the CLI at it:

```bash
ollama run llama3.1:8b
peekaboo agent --model ollama/llama3.1:8b "open System Settings"
```

No network requests leave the machine. Captures, AX queries, and reasoning all stay local.

## Troubleshooting

- **"401 Unauthorized"** — credential isn't set, or env var overrides the saved one. Run `peekaboo config get-credential <provider>`.
- **"context length exceeded"** — long sessions accumulate screenshots. Start a fresh session with `peekaboo agent --new`.
- **"no tool-call support"** — pick a different model. The error log lists the providers and models with confirmed tool-calling.
