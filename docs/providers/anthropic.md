---
summary: 'Configure and use Anthropic Claude models in Peekaboo.'
read_when:
  - 'selecting Claude models or Anthropic credentials'
  - 'debugging Fable limits, generation settings, or compatible endpoints'
---

# Anthropic Claude

Peekaboo uses Tachikoma's native Anthropic Messages integration for API-key and OAuth-backed Claude models, including
tool calls, vision, thinking blocks, and provider-specific event handling.

## Current models

| Model | Context | Max output | Notes |
| --- | ---: | ---: | --- |
| `claude-fable-5` | 1M | 128K | Explicit opt-in for long-horizon agent work. |
| `claude-sonnet-5` | 1M | 128K | Explicit opt-in; not the automatic Anthropic default. |
| `claude-opus-4-8` | 1M | 128K | Default Anthropic choice; compatible with zero-retention organizations. |
| `claude-sonnet-4-6` | 1M | 64K | Balanced speed and capability. |
| `claude-haiku-4-5` | 200K | 64K | Fast, lower-cost tasks. |

Fable 5 and Sonnet 5 are not the automatic Anthropic default. Select either explicitly when your Anthropic
organization allows the model:

```bash
peekaboo agent --model claude-fable-5 "inspect this app and summarize its workflow"
peekaboo agent --model claude-sonnet-5 "inspect this app and summarize its workflow"
```

## Credentials

```bash
peekaboo config add anthropic sk-ant-...
# or
peekaboo config login anthropic
```

Environment credentials remain available for automation:

```bash
ANTHROPIC_API_KEY=sk-ant-... \
  peekaboo agent --model claude-opus-4-8 "describe the current window"
```

## Generation settings

The app and CLI read the same `agent.temperature` and `agent.maxTokens` values from
`~/.peekaboo/config.json`. Peekaboo clamps the token request to the selected model's output capability and strips
sampling parameters from current adaptive-thinking models when the Anthropic API does not accept them.

Fable 5, Sonnet 5, and Opus 4.8 currently use the non-streaming generation path so signed thinking history and
rollback behavior remain valid. Agent progress events still report start, assistant output, tool activity, completion,
and errors.

Anthropic-compatible custom providers inherit known Fable 5 and Sonnet 5 capability limits when their model ID is
`claude-fable-5` or `claude-sonnet-5` (including provider-qualified forms). A custom model's explicit `maxTokens`
value takes precedence for other IDs.

See [configuration.md](../configuration.md) for the shared settings schema and [providers.md](../providers.md) for
the full provider catalog.
