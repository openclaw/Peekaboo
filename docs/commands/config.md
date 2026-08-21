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
| `init` | Create a default `config.json` (respects `--force`) and print provider readiness (env / credentials / OAuth) in human mode. | `--force` overwrites an existing file; `--timeout` bounds live checks (default `30s`; bare values are milliseconds). |
| `show` | Print either the raw file or the fully merged “effective” view (config + env + credentials); human `--effective` also live-validates providers. | `--effective` switches to the merged view; `--timeout` bounds validation with the shared duration grammar; JSON mode emits a standard `{ success, data }` object with no appended text. |
| `edit` | Opens the config in `$EDITOR` (or the `--editor` you pass) and validates the result after you quit. | `--editor` overrides the detected editor. |
| `validate` | Parses the config without writing anything and surfaces syntax/errors. | None. |
| `status` | Display provider credential readiness. | `--timeout` (default `30s`; bare values are milliseconds). |
| `login` | Run an OAuth flow (no API key stored) for supported providers. | `login openai` (ChatGPT/Codex), `login anthropic` (Claude Pro/Max). |
| `credential set` | Validate and store a known provider credential, or store a raw credential key. | With no source, prompts without echo. Scripts use `--credential-stdin --no-input` or an owner-only `--credential-file`; `--timeout` bounds validation. |
| `provider add` | Append or replace a custom AI provider entry. | Positional `<provider-id>` plus `--type openai|anthropic`, `--name`, `--base-url`, `--credential-ref '${NAME}'` or secure credential input, `--headers key:value,…`, `--description`, `--force`, `--dry-run`. |
| `provider list` | Dump configured custom providers plus whether they’re enabled. | `--json` follows the same schema that the runtime loads. |
| `provider test` | Test the configured endpoint and credentials. | Positional `<provider-id>`. |
| `provider remove` | Delete a custom provider entry. | Positional `<provider-id>` plus optional `--force` and `--dry-run`. |
| `provider models` | List configured models offline, or query an OpenAI-compatible provider with `--discover`. | Positional `<provider-id>` plus optional `--discover` and `--save`. |

## Implementation notes
- The underlying auth/config plumbing lives in the shared Tachikoma library and the `tachikoma config` CLI; Peekaboo sets `TachikomaConfiguration.profileDirectoryName = ".peekaboo"` so both tools read/write the same `~/.peekaboo/credentials` without copying environment variables.
- Configuration files are JSON-with-comments: the loader strips `//` / `/* */` comments and interpolates `${VAR}` placeholders before merging with credentials and environment variables (same logic the CLI uses on startup).
- `credential set` and `login` write through the shared configuration/auth managers, using macOS file permissions and atomic temp-file renames. Credential input defaults to a no-echo TTY prompt; redirected stdin is read as one line. `--credential-file` opens nonblocking without following symlinks, then validates and reads that same descriptor; it accepts only a regular file owned by the current user with mode `0400` or `0600` and no extended ACL.
- Provider readiness in human `init`/`show --effective` output is live-validated with per-provider pings (OpenAI/Codex, Anthropic, Grok/xai, Gemini, OpenRouter). Timeouts default to 30s and are caller overridable. JSON mode skips appended readiness text so stdout remains parseable.
- Provider management commands share the same validation helpers: IDs must match `^[A-Za-z0-9-_]+$`, and provider types are limited to `.openai` or `.anthropic`. Non-secret headers passed via `--headers KEY:VALUE,…` are parsed into a `[String:String]` dictionary before being serialized back to disk.
- `provider test` contacts the actual endpoint (respecting proxy, TLS, and custom headers). `provider models` reads configured models without a network request unless `--discover` is passed.
- `provider models --save` preserves existing model capabilities and saves newly discovered models with `supportsTools: false`; enable tool calling in `config.json` only after verifying the endpoint supports it.
- All subcommands are `RuntimeOptionsConfigurable`, so global `--json` or `--verbose` flags work uniformly (handy when you script config changes).

## Examples
```bash
# Create a clean config + show the merged view
peekaboo config init --force
peekaboo config show --effective

# Add and validate an OpenRouter key with the no-echo prompt
peekaboo config credential set openrouter
peekaboo agent --model openrouter/xiaomi/mimo-v2.5-pro "summarize this window"

# Noninteractive input never puts the value in argv
printenv OPENAI_API_KEY | peekaboo config credential set openai --credential-stdin --no-input
peekaboo config credential set anthropic --credential-file /secure/path/anthropic.key --no-input

# OAuth logins (no API key stored)
peekaboo config login openai
peekaboo config login anthropic

# Manage a custom OpenAI-compatible endpoint by non-secret credential reference
printenv LOCAL_OLLAMA_API_KEY | \
  peekaboo config credential set LOCAL_OLLAMA_API_KEY --credential-stdin --no-input
peekaboo config provider add local-ollama \
  --type openai \
  --name "Local Ollama" \
  --base-url "http://localhost:11434/v1" \
  --credential-ref '${LOCAL_OLLAMA_API_KEY}'
peekaboo config provider test local-ollama
peekaboo config provider models local-ollama --discover --save
peekaboo config provider remove local-ollama --force
```

The old positional credential and `provider add --api-key` remain available for script compatibility, but are
deprecated because command arguments are visible to process-listing tools. They emit a warning that never includes
the credential value.

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
