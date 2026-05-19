# OpenRouter Support How-To

This change makes OpenRouter usable as a first-class Peekaboo/Tachikoma provider and lets the agent run OpenRouter model IDs such as `xiaomi/mimo-v2.5-pro`.

## What changed

- Added `openrouter` to Tachikoma provider credentials.
- Added `OPENROUTER_API_KEY` loading from environment and `~/.peekaboo/credentials`.
- Added OpenRouter credential validation via `https://openrouter.ai/api/v1/models`.
- Added OpenRouter default base URL: `https://openrouter.ai/api/v1`.
- Updated OpenRouter attribution header to `X-OpenRouter-Title`.
- Allowed slash-style OpenRouter model IDs in `LanguageModel.parse`, for example `xiaomi/mimo-v2.5-pro`.
- Updated Peekaboo agent model validation to accept OpenRouter models.
- Updated Peekaboo agent preflight checks to treat `OPENROUTER_API_KEY` as a configured AI provider.
- Added `peekaboo config status` to show stored provider credential status.

## Configure OpenRouter

Set and validate the key:

```bash
export OPENROUTER_API_KEY="sk-or-v1-..."
peekaboo config add openrouter "$OPENROUTER_API_KEY"
```

Check provider status:

```bash
peekaboo config status
```

Expected output includes:

```text
OpenRouter: ready (credentials OPENROUTER_API_KEY, validated)
```

## Use an OpenRouter model with the agent

Example using Xiaomi MiMo through OpenRouter:

```bash
peekaboo agent "Take a screenshot of the open Figma app and save it to /tmp/figma-openrouter-agent.png" \
  --model xiaomi/mimo-v2.5-pro \
  --max-steps 4 \
  --simple \
  --no-color
```

For direct screenshot capture without an AI model:

```bash
peekaboo image --app Figma --path /tmp/figma-openrouter-agent.png
```

If screen capture fails, grant macOS permissions:

```bash
peekaboo permissions grant
peekaboo permissions status
```

Required permissions:

```text
Screen Recording: Granted
Accessibility: Granted
```

## Build and reinstall locally

Build the CLI:

```bash
pnpm run build:cli
```

Build release:

```bash
pnpm run build:cli:release
```

If using the Homebrew-installed binary during local development, replace the active binary:

```bash
cp Apps/CLI/.build/release/peekaboo /opt/homebrew/Cellar/peekaboo/3.2.1/bin/peekaboo
```

Verify:

```bash
peekaboo --version
peekaboo config status
```

## Tests run

Focused Tachikoma tests:

```bash
swift test --filter 'LanguageModelCoverageTests'
```

Focused CLI tests:

```bash
swift test --filter 'AgentCommandTests|ModelSelectionIntegrationTests'
swift test --filter 'CommanderBinderAppConfigTests'
```

CLI build:

```bash
pnpm run build:cli
pnpm run build:cli:release
```

## LinkedIn draft

I added OpenRouter support to Peekaboo so the desktop automation agent can run models by provider/model ID, including `xiaomi/mimo-v2.5-pro`.

The update adds credential storage and validation for `OPENROUTER_API_KEY`, OpenRouter model parsing in Tachikoma, and CLI agent support for slash-style OpenRouter model IDs. I used it to drive a Peekaboo agent task against an open Figma window and validate the end-to-end path from model selection to desktop automation.

Small change, useful outcome: Peekaboo can now use a much wider model surface without hardcoding every provider model into the CLI.
