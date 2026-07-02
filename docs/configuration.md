---
summary: 'Reference for Peekaboo configuration precedence, environment variables, and credential handling.'
read_when:
  - 'setting environment variables or editing ~/.peekaboo/config.json'
  - 'debugging why CLI settings are not applied'
---

# Configuration & Environment Variables

## Precedence

Peekaboo resolves settings in this order (highest → lowest):

1. Command-line arguments
2. Environment variables (never copied into files)
3. Credentials file (`~/.peekaboo/credentials`: API keys or OAuth tokens)
4. Configuration file (`~/.peekaboo/config.json`)
5. Built-in defaults

## Available Options

| Setting | Config File | Environment Variable | Description |
|---------|-------------|---------------------|-------------|
| AI Providers | `aiProviders.providers` | `PEEKABOO_AI_PROVIDERS` | Comma-separated list (`openai/gpt-5.5,anthropic/claude-opus-4-8,grok/grok-4.3,ollama/llava:latest`). First healthy provider wins. |
| Agent Model | `agent.defaultModel` | `PEEKABOO_AGENT_MODEL` | Default model for `peekaboo agent`; CLI `--model` wins. |
| Agent Temperature | `agent.temperature` | - | Sampling temperature shared by the app and CLI (default `0.7`); clamped or omitted for models that restrict it. |
| Agent Max Tokens | `agent.maxTokens` | - | Requested output-token budget shared by the app and CLI (default `16384`, accepted range `1...128000`); clamped to provider capability. |
| OpenAI API Key | credentials file | `OPENAI_API_KEY` | Required for OpenAI models. |
| Anthropic API Key | credentials file | `ANTHROPIC_API_KEY` | Required for Claude models (API-key path). |
| Anthropic OAuth | credentials file | `ANTHROPIC_REFRESH_TOKEN`, `ANTHROPIC_ACCESS_TOKEN`, `ANTHROPIC_ACCESS_EXPIRES` | Created by `config login anthropic`; no API key stored. |
| Grok API Key | credentials file | `GROK_API_KEY` / `X_AI_API_KEY` / `XAI_API_KEY` | Required for Grok (xAI). Env alias resolves to Grok. |
| Gemini API Key | credentials file | `GEMINI_API_KEY` | Required for Gemini. |
| MiniMax API Key | credentials file | `MINIMAX_API_KEY` | Required for MiniMax international; also works as fallback for MiniMax China. |
| MiniMax China API Key | credentials file | `MINIMAX_CN_API_KEY` | Optional China-specific key for `minimax-cn/...` models. |
| Ollama URL | `aiProviders.ollamaBaseUrl` | `PEEKABOO_OLLAMA_BASE_URL` | Base URL for local/remote Ollama (default `http://localhost:11434`). |
| Default Save Path | `defaults.savePath` | `PEEKABOO_DEFAULT_SAVE_PATH` | Directory for screenshots (supports `~`). |
| Log Level | `logging.level` | `PEEKABOO_LOG_LEVEL` | `trace`, `debug`, `info`, `warn`, `error`, `fatal` (default `info`). |
| Log Path | `logging.path` | `PEEKABOO_LOG_FILE` | Custom log destination (default `/tmp/peekaboo-mcp.log` for MCP; CLI uses stderr). |
| CLI Binary Path | - | `PEEKABOO_CLI_PATH` | Override bundled CLI when testing custom builds. |
| Auto daemon socket | - | `PEEKABOO_DAEMON_SOCKET` | Override the socket used for auto-started daemons (mainly tests/dev). |
| Auto daemon idle timeout | - | `PEEKABOO_DAEMON_IDLE_TIMEOUT_SECONDS` | Seconds before an auto-started daemon exits while idle (default 300). |
| Tool allow-list | `tools.allow` | `PEEKABOO_ALLOW_TOOLS` | CSV or space list. If set, only these tools are exposed (env replaces config). |
| Tool deny-list | `tools.deny` | `PEEKABOO_DISABLE_TOOLS` | CSV or space list. Always removed; env list is additive with config. |
| UI input strategy | `input.*` | `PEEKABOO_INPUT_STRATEGY` and per-verb variants | Choose action invocation versus synthetic input. Built-in policy uses `actionFirst` for click/scroll and `synthFirst` for type/hotkey. |

## API Key Storage

1. **Environment variables** – most secure for automation: `export OPENAI_API_KEY="sk-..."`.
2. **Credentials file** – `peekaboo config set-credential OPENAI_API_KEY sk-...` stores secrets in `~/.peekaboo/credentials` (`chmod 600`).
3. **Config file** – avoid storing keys here unless absolutely necessary. OAuth tokens are never written to `config.json`.

## Provider Variables

- `PEEKABOO_AI_PROVIDERS`: `provider/model` CSV. Example: `openai/gpt-5.5,anthropic/claude-opus-4-8,grok/grok-4.3,ollama/llava:latest`.
- `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GROK_API_KEY` | `X_AI_API_KEY` | `XAI_API_KEY`, `GEMINI_API_KEY`: required for their respective providers when using API keys.
- `PEEKABOO_OLLAMA_BASE_URL`: change when your Ollama daemon isn’t on `localhost:11434`.

## Defaults & Paths

- `PEEKABOO_DEFAULT_SAVE_PATH`: screenshot destination (created automatically).
- `PEEKABOO_CLI_PATH`: point Peekaboo at a debug build (`.build/debug/peekaboo`) without copying binaries around.

## Agent generation settings

The macOS Settings UI and `peekaboo agent` share `agent.temperature` and `agent.maxTokens` through
`~/.peekaboo/config.json`:

```json
{
  "agent": {
    "defaultModel": "anthropic/claude-fable-5",
    "temperature": 0.7,
    "maxTokens": 128000
  }
}
```

`maxTokens` is an upper request, not a promise: Peekaboo clamps it to the selected model's advertised output limit.
Fable 5 supports up to 128K output and a 1M context window. Anthropic-compatible custom providers inherit known
Fable limits from the model ID, while custom model entries can advertise their own `maxTokens`.

Temperature is clamped to `0...1` for Anthropic-compatible models and `0...2` elsewhere. Peekaboo omits it entirely
for models that reject sampling controls, including GPT-5-compatible endpoints and current Anthropic adaptive-thinking
models.

## UI Input Strategy

Input strategy controls whether UI interactions use accessibility action invocation or synthetic input. The built-in
policy keeps the global default at `synthFirst`, flips click and scroll to `actionFirst`, keeps type and hotkey at
`synthFirst`, and exposes `setValue`/`performAction` as action-only operations.

Precedence is `--input-strategy` CLI flag, then environment, then config file, then built-in default. The CLI flag forces local execution because the current bridge protocol does not forward per-call strategy overrides.

Valid values:

- `actionFirst`: try accessibility action invocation, fall back to synthetic input when unsupported.
- `synthFirst`: use synthetic input first.
- `actionOnly`: use action invocation only.
- `synthOnly`: use synthetic input only.

Config example:

```json
{
  "input": {
    "defaultStrategy": "synthFirst",
    "click": "actionFirst",
    "scroll": "actionFirst",
    "type": "synthFirst",
    "hotkey": "synthFirst",
    "setValue": "actionOnly",
    "performAction": "actionOnly",
    "perApp": {
      "com.googlecode.iterm2": {
        "hotkey": "synthOnly"
      }
    }
  }
}
```

Environment variables:

- `PEEKABOO_INPUT_STRATEGY`
- `PEEKABOO_CLICK_INPUT_STRATEGY`
- `PEEKABOO_SCROLL_INPUT_STRATEGY`
- `PEEKABOO_TYPE_INPUT_STRATEGY`
- `PEEKABOO_HOTKEY_INPUT_STRATEGY`
- `PEEKABOO_SET_VALUE_INPUT_STRATEGY`
- `PEEKABOO_PERFORM_ACTION_INPUT_STRATEGY`

CLI override:

```bash
peekaboo click --on "$ELEMENT_ID" --input-strategy actionFirst
```

## Logging & Troubleshooting

- `PEEKABOO_LOG_LEVEL=debug` (or `trace`) surfaces verbose input-path logs.
- `PEEKABOO_LOG_FILE=/tmp/peekaboo.log` persists logs for sharing.
- Tool filters: env `PEEKABOO_ALLOW_TOOLS` replaces config `tools.allow`; env `PEEKABOO_DISABLE_TOOLS` is additive with `tools.deny`. Deny wins if a tool appears in both. See [docs/security.md](security.md) for examples and risk guidance.

## Setting Variables

```bash
# Single command
PEEKABOO_AI_PROVIDERS="ollama/llava:latest" peekaboo image --analyze "Describe this UI" --path img.png

# Session exports
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
export X_AI_API_KEY="xai-..."

# Shell profile
echo 'export OPENAI_API_KEY="sk-..."' >> ~/.zshrc
```

When in doubt, run `peekaboo config show --effective` to see the merged view from every layer.
