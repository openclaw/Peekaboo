---
summary: 'Drive Peekaboo’s autonomous agent via peekaboo agent'
read_when:
  - 'testing natural-language automation end-to-end'
  - 'resuming or debugging cached agent sessions'
---

# `peekaboo agent`

`agent` hands a natural-language task to `PeekabooAgentService`, which in turn orchestrates the full toolset (see, click, type, menu, etc.). The command handles session caching, terminal capability detection, progress spinners, and audio capture so you can run the exact same agent loop the macOS app uses.

## Key options
| Flag | Description |
| --- | --- |
| `[task]` | Optional free-form task description. Required unless you pass `--resume`/`--resume-session`. |
| `--chat` | Force the interactive chat loop even when stdin/stdout are not TTYs. |
| `--dry-run` | Emit the planned steps without actually invoking tools. |
| `--max-steps <n>` | Cap how many tool invocations the agent may issue before aborting (default: 100). |
| `--model gpt-5.6|gpt-5.5|claude-fable-5|claude-sonnet-5|gemini-3-flash|minimax|minimax-cn/<model>|openrouter/<provider>/<model>|ollama/<model>|lmstudio/<model>` | Override the default model (`gpt-5.5`). Input is validated against supported hosted providers and local model providers. |
| `--resume` / `--resume-session <id>` | Continue the most recent session or a specific session ID. |
| `--list-sessions` | Print cached sessions (id, task, timestamps, message count) instead of running anything. |
| `--no-cache` | Always create a fresh session even if one is already active. |
| `--quiet` / `--simple` / `--no-color` / `--debug-terminal` | Control output mode; the command auto-detects terminal capabilities when you don’t override it. |
| `--audio` / `--audio-file <path>` / `--realtime` | Use microphone input, pipe audio from disk, or enable OpenAI’s realtime audio mode. |

## Implementation notes
- The command resolves output “modes” (`minimal`, `compact`, `enhanced`, `quiet`, `verbose`) using terminal detection heuristics; `--simple` and `--no-color` force minimal mode, while `--quiet` suppresses progress output entirely.
- Session metadata lives inside `agentService` (PeekabooCore). `--resume` grabs the most recent session, `--list-sessions` prints the cached list, and `--no-cache` disables reuse so each run starts clean.
- All agent executions run under `CommandRuntime.makeDefault()`, so environment variables, credentials, and logging levels match the top-level CLI state.
- When `--dry-run` is set the agent still reasons about the task, but tool invocations are skipped; this is useful for understanding plans without touching the UI.
- Audio flags wire into Tachikoma’s audio stack: `--audio` opens the microphone, `--audio-file` loads a WAV/CAF file, and `--realtime` enables low-latency streaming (OpenAI-only).
- Generation uses `agent.temperature` and `agent.maxTokens` from the shared config written by the macOS Settings UI.
  Token requests are capped to model capability; unsupported temperature controls are omitted automatically.

## Chat mode

Peekaboo now ships a dependency-free interactive chat loop described in detail in `docs/agent-chat.md`. Key behaviors:

- Running `peekaboo agent` without a task automatically enters chat mode when stdout is a TTY. Non-interactive shells print the chat help menu instead of hanging.
- `--chat` forces the loop even when piped or redirected, making it easy for other agents to seed prompts programmatically.
- `/help` is available inside the loop at any time and is printed the moment the loop starts. `/help` is also mentioned in the initial “Type /help…” banner so operators know what to do.
- Pressing `Esc` during an active turn cancels the run immediately and brings you back to the prompt; Ctrl+C still works as a fallback.
- Chat sessions reuse context via the same agent session cache. Supplying `--resume` / `--resume-session <id>` before `--chat` hooks the loop into an existing conversation.
- Ctrl+C cancels the current turn; pressing it again (while idle) exits the loop. Ctrl+D exits when idle.

For automation flows that cannot attach to a TTY, pass both `--chat` and standard input (e.g., echoing prompts line-by-line). Without `--chat`, a non-interactive invocation simply prints the chat help instructions and exits so jobs don’t hang.

## Examples
```bash
# Let the agent sign into Slack using GPT-5.5 with verbose tracing
peekaboo agent "Check Slack mentions" --model gpt-5.5 --verbose

# Use GPT-5.6 Sol (the gpt-5.6 shortcut selects Sol)
peekaboo agent "Check the current window" --model gpt-5.6

# Use Claude Sonnet 5
peekaboo agent "Check the current window" --model claude-sonnet-5

# Keep the agent loop local through Ollama
peekaboo agent "Check the current window" --model ollama/llama3.3

# Use an OpenRouter-hosted model
peekaboo agent "Check the current window" --model openrouter/xiaomi/mimo-v2.5-pro

# Dry-run the same task without executing any tools
peekaboo agent "Install the nightly build" --dry-run

# Resume the last session and quiet the spinner output
peekaboo agent --resume --quiet
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
