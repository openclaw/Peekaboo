---
summary: 'Index of AI provider docs (OpenAI, Anthropic, Gemini, MiniMax, Kimi, Grok, Ollama).'
read_when:
  - 'choosing or configuring AI providers for Peekaboo'
  - 'looking for provider-specific plans or status'
---

# Providers index

- **OpenAI** — `openai.md`: architecture, migration status, and guidance for adding models.
- **Anthropic** — `anthropic.md`: Fable 5, Sonnet 5, and other Claude models, output limits, generation settings, and credentials.
- **Google** — configured with `GEMINI_API_KEY`; supports Gemini 3.1 Pro Preview and Gemini 3 Flash.
- **MiniMax** — configured with `MINIMAX_API_KEY`; supports MiniMax M3 and M2.7 through the Anthropic-compatible API.
- **MiniMax China** — use `minimax-cn/...` with `MINIMAX_CN_API_KEY` or the shared `MINIMAX_API_KEY`; routes to `api.minimaxi.com`.
- **Kimi** — use `kimi/...` with `MOONSHOT_API_KEY` or `KIMI_API_KEY`; supports Kimi K2.6 and K2.7 Code through Moonshot's coding API.
- **Grok** — `grok.md`: Grok 4 implementation guide and checkpoints.
- **Ollama** — `ollama.md`: native API, endpoints, tool history, and streaming behavior; `ollama-models.md` for
  capability-first model selection.

Use [`docs/providers.md`](../providers.md) as the central reference for the user-facing provider list,
configuration syntax, and environment variable reference.

## Capability quick-compare

| Provider | Tools | Vision | Streaming | Local/offline | Auth |
| --- | --- | --- | --- | --- | --- |
| OpenAI | Yes (function/tool calling) | Yes | Yes | No | API key or OAuth |
| Anthropic | Yes | Yes | Model-dependent; Fable 5, Sonnet 5, and Opus 4.8 currently non-streaming | No | API key or OAuth (Claude Pro/Max) |
| Google | Yes | Yes | Yes | No | API key |
| MiniMax | Yes | Model-dependent | Yes | No | API key |
| MiniMax China | Yes | Model-dependent | Yes | No | API key |
| Kimi | Yes | Yes | Yes | No | API key |
| Grok | Yes | Limited | Yes | No | API key |
| Ollama | Model-dependent | Model-dependent | Incremental NDJSON | Model-dependent; disable cloud for strict local use | None for local models |
| LM Studio | Yes (OpenAI-compatible local server) | Model-dependent | Yes | **Yes** (local) | None by default |

See individual pages for model lists, quirks, and test coverage expectations.
