---
summary: 'Manage Peekaboo configuration and AI providers via peekaboo config'
read_when:
  - 'editing ~/.peekaboo/config.json or credentials safely'
  - 'adding/testing custom AI providers and API keys'
---

# `peekaboo config`

`peekaboo config` owns everything under `~/.peekaboo/`: the JSONC config file, the credential store, and the list of custom AI providers. Each subcommand runs on the main actor so it can call the same `ConfigurationManager` used by the CLI at startup, which means the output always reflects what the runtime will actually load.

## Subcommands
| Subcommand | Purpose | Key flags |
| --- | --- | --- |
| `init` | Create a default `config.json` (respects `--force`) and print provider readiness (env / credentials / OAuth) in human mode. | `--force` overwrites an existing file; `--timeout` (sec) to bound live checks (default 30). |
| `show` | Print either the raw file or the fully merged “effective” view (config + env + credentials); human `--effective` also live-validates providers. | `--effective` switches to the merged view; `--timeout` (sec) bounds validation; JSON mode emits a standard `{ success, data }` object with no appended text. |
| `edit` | Opens the config in `$EDITOR` (or the `--editor` you pass) and validates the result after you quit. | `--editor` overrides the detected editor. |
| `validate` | Parses the config without writing anything and surfaces syntax/errors. | None. |
| `add` | Store a provider credential and validate it immediately. | `add openai|anthropic|grok|gemini <secret>`; `--timeout` (sec, default 30). |
| `login` | Run an OAuth flow (no API key stored) for supported providers. | `login openai` (ChatGPT/Codex), `login anthropic` (Claude Pro/Max). |
| `set-credential` | Legacy alias for `add <key> <value>`. | Positional `<key> <value>` pair. |
| `add-provider` | Append or replace a custom AI provider entry. | `--type openai|anthropic`, `--name`, `--base-url`, `--api-key`, `--headers key:value,…`, `--description`, `--force`. |
| `list-providers` | Dump built-in + custom providers plus whether they’re enabled. | `--json` follows the same schema that the runtime loads. |
| `test-provider` | Fires a quick `/models` request (or Anthropic equivalent) against the provider definition to make sure credentials/base URL are valid. | `--provider-id <id>` (required), `--timeout-ms`, `--model`. |
| `remove-provider` | Delete a custom provider entry. | `--provider-id <id>` and optional `--force` to skip confirmation. |
| `models` | Enumerate every model Peekaboo knows about (native, providers, or the specific server you pass). | `--provider-id`, `--include-disabled`. |

## Implementation notes
- The underlying auth/config plumbing lives in the shared Tachikoma library and the `tachikoma config` CLI; Peekaboo sets `TachikomaConfiguration.profileDirectoryName = ".peekaboo"` so both tools read/write the same `~/.peekaboo/credentials` without copying environment variables.
- Configuration files are JSON-with-comments: the loader strips `//` / `/* */` comments and interpolates `${VAR}` placeholders before merging with credentials and environment variables (same logic the CLI uses on startup).
- `add`/`login`/`set-credential` write through `ConfigurationManager.shared`, so they use macOS file permissions + atomic temp-file renames; partial writes won’t corrupt the store even if the process crashes.
- Provider readiness in human `init`/`show --effective` output is live-validated with per-provider pings (OpenAI/Codex, Anthropic, Grok/xai, Gemini). Timeouts default to 30s and are caller overridable. JSON mode skips appended readiness text so stdout remains parseable.
- Provider management commands share the same validation helpers: IDs must match `^[A-Za-z0-9-_]+$`, and provider types are limited to `.openai` or `.anthropic`. Headers passed via `--headers KEY:VALUE,…` are parsed into a `[String:String]` dictionary before being serialized back to disk.
- `test-provider` and `models` invoke the actual HTTP client stack (respecting proxy, TLS, and custom headers) rather than mocking responses, which is why they run on the main actor and surface real latencies.
- All subcommands are `RuntimeOptionsConfigurable`, so global `--json` or `--verbose` flags work uniformly (handy when you script config changes).

## Examples
```bash
# Create a clean config + show the merged view
peekaboo config init --force
peekaboo config show --effective

# Register OpenRouter as a provider and immediately test it
peekaboo config add-provider openrouter \
  --type openai \
  --name "OpenRouter" \
  --base-url https://openrouter.ai/api/v1 \
  --api-key "${OPENROUTER_API_KEY}" --force
peekaboo config test-provider --provider-id openrouter

# Add and validate keys (stores even if validation fails; warns on failure)
peekaboo config add openai sk-live-...
peekaboo config add anthropic sk-ant-...
peekaboo config add grok xai-...
peekaboo config add gemini ya29...

# OAuth logins (no API key stored)
peekaboo config login openai
peekaboo config login anthropic
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
