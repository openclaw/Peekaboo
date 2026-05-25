---
summary: 'Index of AI provider docs (OpenAI, Anthropic, Gemini, MiniMax, Grok, Ollama)'
read_when:
  - 'choosing or configuring AI providers for Peekaboo'
  - 'looking for provider-specific plans or status'
---

# Providers index

- **OpenAI** — `openai.md`: architecture, migration status, and guidance for adding models.
- **Anthropic** — `anthropic.md`: plan/status, streaming/tool notes, and Claude CLI examples.
- **Google** — configured with `GEMINI_API_KEY`; supports Gemini 3.1 Pro Preview and Gemini 3 Flash.
- **MiniMax** — configured with `MINIMAX_API_KEY`; supports MiniMax M2.7 through the Anthropic-compatible API.
- **MiniMax China** — use `minimax-cn/...` with `MINIMAX_CN_API_KEY` or the shared `MINIMAX_API_KEY`; routes to `api.minimaxi.com`.
- **Grok** — `grok.md`: Grok 4 implementation guide and checkpoints.
- **Ollama** — `ollama.md`: local model configuration; `ollama-models.md` for model catalog notes.

Use [`docs/providers.md`](../providers.md) as the central reference for the user-facing provider list,
configuration syntax, and environment variable reference.

## Capability quick-compare

| Provider | Tools | Vision | Streaming | Local/offline | Auth |
| --- | --- | --- | --- | --- | --- |
| OpenAI | Yes (function/tool calling) | Yes (gpt-4o/4.1) | Yes | No | API key |
| Anthropic | Yes | Yes (Sonnet/Opus vision) | Yes (SSE) | No | API key or OAuth (Claude Pro/Max) |
| Google | Yes | Yes | Yes | No | API key |
| MiniMax | Yes | No | Yes | No | API key |
| MiniMax China | Yes | No | Yes | No | API key |
| Grok | Yes | Limited | Yes | No | API key |
| Ollama | Yes (via local server) | Model-dependent | Yes | **Yes** (local) | None (local daemon) |
| LM Studio | Yes (OpenAI-compatible local server) | Model-dependent | Yes | **Yes** (local) | None by default |

See individual pages for model lists, quirks, and test coverage expectations.
