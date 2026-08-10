---
summary: 'How Peekaboo handles OAuth for OpenAI/Codex and Anthropic (Claude Pro/Max)'
read_when:
  - 'adding or debugging OAuth logins for OpenAI or Anthropic'
  - 'explaining where tokens are stored and how they refresh'
---

# OAuth flows (OpenAI/Codex and Anthropic Max)

Peekaboo supports OAuth for two providers:
- **OpenAI/Codex** via `peekaboo config login openai`
- **Anthropic Claude Pro/Max** via `peekaboo config login anthropic`

These flows avoid storing API keys and instead keep refresh/access tokens in `~/.peekaboo/credentials` (chmod 600).

> Peekaboo shares the same credential layout as Tachikoma. Hosts can swap the profile directory (`TachikomaConfiguration.profileDirectoryName`). Credentials supplied through the environment are never copied into the file. Refreshed environment OAuth tokens remain in memory for the current process; use `peekaboo config login` when the rotated refresh chain must persist across launches.

## What happens during login
1. Generate PKCE values and open the provider’s authorize URL in the browser (also printed for headless use).
2. You paste the returned `code` (and `state` when required) into the CLI.
3. Peekaboo exchanges the code for `refresh` + `access` tokens and stores:
   - `OPENAI_REFRESH_TOKEN`, `OPENAI_ACCESS_TOKEN`, `OPENAI_ACCESS_EXPIRES` **or**
   - `ANTHROPIC_REFRESH_TOKEN`, `ANTHROPIC_ACCESS_TOKEN`, `ANTHROPIC_ACCESS_EXPIRES`
4. No API key is written for OAuth flows.

## How requests are sent

- Providers resolve OAuth tokens and API keys through the shared Tachikoma credential manager. If a stored access token is expired, Peekaboo refreshes it and atomically updates the credentials file. Environment-supplied OAuth sessions refresh only in memory.
- OpenAI OAuth requests use the ChatGPT Codex Responses backend and include the ChatGPT account identifier from the access token. Text and image inputs are supported, including `see --analyze`, `image --analyze`, and agent vision calls.
- Anthropic requests include the beta header used for Claude Max: `anthropic-beta: oauth-2025-04-20,claude-code-20250219,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14`.
- An explicit OpenAI API key remains higher priority and uses the public OpenAI API rather than the Codex OAuth transport.

## Validating connectivity

- `peekaboo config show --timeout 30s` pings each configured provider and reports status (`ready (validated)`, `stored (validation failed: <reason>)`, `missing`).
- `peekaboo config credential set <provider> <secret>` validates immediately; failures are stored but warned.

## Revoking access

- **OpenAI/Codex**: revoke from your OpenAI account security page; then delete the stored tokens (`peekaboo config edit` or remove the keys from `~/.peekaboo/credentials`).
- **Anthropic**: revoke from your Claude account; remove the stored tokens the same way.

## Headless / CI

- If the browser cannot open, the CLI still prints the authorize URL; paste the resulting code back. Access/refresh storage and refresh logic are identical.

## Troubleshooting

- If validation fails after login, run `peekaboo config show --timeout 10s --verbose` to see the provider error.
- Stale access tokens are refreshed automatically; if refresh fails, rerun `peekaboo config login <provider>`.
