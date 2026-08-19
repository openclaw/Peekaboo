---
summary: 'Drive Peekaboo’s autonomous agent via peekaboo agent'
read_when:
  - 'testing natural-language automation end-to-end'
  - 'resuming or debugging cached agent sessions'
---

# `peekaboo agent`

`agent` hands a natural-language task to `PeekabooAgentService`, which in turn orchestrates the full toolset (see, click, type, menu, etc.). The command handles session caching, terminal capability detection, progress spinners, and audio capture so you can run the exact same agent loop the macOS app uses.

## Subcommands and options
| Command or flag | Description |
| --- | --- |
| `run [task]` | Run a task. `run` is the default, so `peekaboo agent "task"` remains valid. |
| `resume [session-id]` | Resume the most recent session, or the exact full session ID, in chat mode. |
| `sessions` | Print cached sessions with full IDs, tasks, lifecycle status, and stored policy maximum; accepts only the global `--json` output switch. |
| `chat [initial-prompt]` | Start the interactive chat loop. |
| `--dry-run` | Emit a deterministic preview of a required text task without calling a model, invoking tools, transcribing audio, or creating a session. Human output names the requested foreground choice and effective UI authority. JSON also includes `uiAuthority.requestedForeground`, `uiAuthority.effectivePolicy`, and `uiAuthority.backgroundOnly`. |
| `--max-steps <n>` | Cap model turns to `1...100` (default: 100). One turn may contain multiple tool calls. |
| `--model gpt-5.6|gpt-5-mini|claude-opus-5|claude-fable-5|claude-sonnet-5|gemini-3-flash|minimax|minimax-cn/<model>|openrouter/<provider>/<model>|ollama/<model>|lmstudio/<model>` | Override the configured model. Concrete OpenAI and Anthropic selections are preserved; generic `gpt`/`openai` select GPT-5.6 Sol. Input is validated against supported hosted providers and local model providers. |
| `--no-cache` | Run ephemerally without saving a resumable session. Cannot be combined with resume/list flags. |
| `--allow-foreground` | Human opt-in for this invocation to use foreground/global UI routes. New sessions persist it as an immutable maximum; each later resume must opt in again. It never exposes the Shell tool. |
| `--quiet` / `--simple` / `--no-color` / `--debug-terminal` | Control output mode; the command auto-detects terminal capabilities when you don’t override it. |
| `--audio` / `--audio-file <path>` | Use microphone input or pipe audio from disk. |

## Implementation notes
- The command resolves output “modes” (`minimal`, `compact`, `enhanced`, `quiet`, `verbose`) using terminal detection heuristics; `--simple` and `--no-color` force minimal mode, while `--quiet` suppresses progress output entirely.
- Session metadata lives inside `agentService` (PeekabooCore). `agent resume` grabs the most recent session, `agent sessions` prints the cached list, and `--no-cache` keeps a run in memory.
- Copy the full ID printed by `agent sessions`; shortened prefixes are display hints, not valid resume identifiers. A status
  of `active` means the saved session is resumable, not that a process is currently executing or that the session is
  free for concurrent use. Use one process per session; if another run is using it, wait and retry the same full ID.
- Every new Agent session is background-only by default. Provider and MCP arguments are validated first; the runtime
  then enforces the immutable authority ceiling before dispatch, including foreground aliases, shared-pointer tools,
  focus/activation, foreground capture, global shared system UI mutations, Space switch/follow, persistent clipboard
  writes, browser setup, and browser page fronting. Space listing and unfollowed window moves remain available.
  Refusals report `effect: refused`,
  `mutation_dispatched: false`, and `retry_safe: true`.
- Background-only Agent raw `press` requires a fresh exact non-dialog snapshot receipt. Targetless, app/PID-only,
  window-selector-only, and `foreground: true` forms are refused. Its semantic effect is unverifiable, so observe the
  exact target before another mutation.
- Exact targeted `dialog click`, non-forced `dismiss`, and `input` remain available with an explicit app, PID, or
  window target. Click/dismiss use prepared one-shot receipts; input resolves the exact target and uses background
  AXValue. Targetless input, file actions, forced dismiss, and foreground routes remain unavailable.
- `--allow-foreground` is accepted only as human authority. A new session saves foreground permission as its immutable
  maximum, but every later process invocation defaults back to background-only and must pass the flag again. A
  background-only session cannot be broadened on resume, and editing session JSON cannot authorize foreground work.
  Each continuation regenerates its system prompt for the current invocation ceiling, so a stored foreground-capable
  session resumed without the flag does not keep foreground examples or guidance.
- Background-only Agent typing requires an explicit fresh exact non-dialog snapshot; an optional element ID must come
  from that snapshot. Snapshot typing cannot include competing app/PID/window selectors. Direct-text paste
  remains available through a generation-pinned app/PID/window authorization with a canonical background result.
  Targetless, foreground, current-clipboard, and binary paste remain refused.
- Foreground permission never exposes the Shell tool. Normal Agent toolsets omit `shell`, and the execution boundary
  still refuses it after `--allow-foreground`. Foreground UI authority is not a process sandbox: a trusted prompt can
  operate terminal or scripting apps through their UI, so grant `--allow-foreground` only to trusted prompts. Use
  Peekaboo's native app/window/Accessibility/browser tools for UI automation.
- Agent execution stays in the caller process by default. Pass the global `--bridge-socket <path>` option to route its tools through one specific Bridge host; `--no-remote` keeps the run strictly caller-local.
- Protocol 1.31 qualification can instead ask an eligible Bridge host to launch the exact authenticated Peekaboo CLI
  peer for one fixed background-only `agent run --no-cache --bridge-socket <serving-host> --json` execution. This is one
  long request through terminal `waitpid`, not a public two-call Agent lifecycle. The host accepts the task but no
  executable, shell, AppleScript, JXA, arbitrary argv, or environment input. The CLI blocks at its earliest entry point
  on a host-owned anonymous pipe, so `SIGCONT` alone cannot pass the exact process/code/path and owner-private
  challenge acknowledgement gate. The outer request owns no desktop lane, while each nested tool call owns its exact
  lane and signed receipt. The fixed background toolset omits Shell; process-group cleanup is not a general macOS
  sandbox against a compromised signed CLI or native code that deliberately detaches. A pre-1.31 or
  capability-disabled host refuses before launch, and a response lost after pipe release is retry-unsafe. Its
  qualification-only CLI adapter emits the canonical signed receipt bundle and is deliberately absent from help and
  shell completions; ordinary users should invoke `peekaboo agent` directly.
- An unrelated legacy ScreenCaptureKit owner does not block Agent startup or non-capturing app/window/Accessibility
  tools through an explicitly selected current Bridge. Pixel-producing calls remain refused before dispatch for that
  process lifetime; after fixing the owner, start a fresh Agent process before retrying capture.
- All agent executions run under `CommandRuntime.makeDefault()`, so environment variables, credentials, and logging levels match the top-level CLI state.
- New configurations select GPT-5.6 and Opus 5. Credential-only Anthropic discovery uses Opus 4.8 for zero-retention compatibility, while saved configuration and session model pins remain unchanged.
- `--dry-run` is a zero-provider text-task preview: it echoes the normalized instruction with explicit zero
  model/tool/session effects. A missing task or audio input is invalid instead of entering chat/help or transcription.
- Audio flags wire into Tachikoma’s audio stack: `--audio` opens the microphone and `--audio-file` loads a WAV/CAF file.
- Generation uses `agent.temperature` and `agent.maxTokens` from the shared config written by the macOS Settings UI.
  Token requests are capped to model capability; unsupported temperature controls are omitted automatically.
- Unless `--no-cache` is set, a run saves its session and fails when its final permitted turn still requests tools and therefore needs another
  model turn to interpret their results. This avoids reporting an empty success when the step budget expires with
  pending work; resume the reported session to continue.
- Native `ollama/<model>` runs replay each assistant tool call and named tool result on the next model turn. Ollama
  support is model-dependent, and native text arrives incrementally with a model-dependent chunk cadence. See the
  [Ollama guide](../providers/ollama.md).

### JSON execution trace

`--json` retains the legacy `result.toolCalls` array for compatibility and adds
`result.executionTrace`. The trace correlates each provider-emitted call ID with its runtime result and reports one of
four dispositions: `executed/succeeded`, `executed/failed`, `skipped-before-dispatch`, or `missing-result`. This lets a
validator distinguish a model's attempted calls from mutations Peekaboo actually dispatched.

`executionTrace.entries[].arguments` is a JSON object rather than the legacy string preview. Trace arguments are
bounded and allowlist only audit-relevant targeting, delivery modes, action enums, timeouts, predicate kinds, and safe
boolean controls. Content-bearing and unknown values are represented by typed redaction summaries, including typed or
pasted text, expected values, messages, prompts, shell commands, URLs, open targets, queries, labels, paths, and binary
image data. Each `result` is a bounded status summary, not the raw tool payload; screenshot bytes and arbitrary output
text are intentionally omitted. The trace is capped at 512 entries and reports `totalCallCount` plus `truncated` when
calls were omitted.

Mutating trace entries expose `mutationDispatch` as `dispatched`, `not_dispatched`, or `possibly_dispatched`.
`mutation_dispatched` is retained in the bounded result summary only when the tool explicitly reported the legacy
boolean (or Peekaboo itself skipped the call before dispatch). Older or opaque results are `possibly_dispatched`, omit
the legacy boolean, and report `retry_safe: false` so clients do not replay a mutation whose dispatch is unknown.

## Chat mode

Peekaboo now ships a dependency-free interactive chat loop described in detail in `docs/agent-chat.md`. Key behaviors:

- Running `peekaboo agent` without a task automatically enters chat mode when stdout is a TTY. `agent resume [session-id]` also enters chat so piped prompts can continue the saved session.
- `agent chat` forces the loop even when piped or redirected, making it easy for other agents to seed prompts programmatically.
- `/help` is available inside the loop at any time and is printed the moment the loop starts. `/help` is also mentioned in the initial “Type /help…” banner so operators know what to do.
- Pressing `Esc` during an active turn cancels the run immediately and brings you back to the prompt; Ctrl+C still works as a fallback.
- Chat sessions reuse context via the same agent session cache; use `agent resume [session-id]` to hook the loop into an existing conversation.
- Ctrl+C cancels the current turn; pressing it again (while idle) exits the loop. Ctrl+D exits when idle.

For automation flows that cannot attach to a TTY, use `agent chat` with standard input. Session resumes also consume standard input and exit nonzero when a resumed turn fails; explicit `agent chat` keeps the loop alive.

## Examples
```bash
# Let the agent sign into Slack using GPT-5.6 with verbose tracing
peekaboo agent "Check Slack mentions" --model gpt-5.6 --verbose

# Use GPT-5.6 Sol (the gpt-5.6 shortcut selects Sol)
peekaboo agent "Check the current window" --model gpt-5.6

# Use Claude Sonnet 5
peekaboo agent "Check the current window" --model claude-sonnet-5

# Keep the agent loop local through Ollama
peekaboo agent "Check the current window" --model ollama/llama3.3

# Use an OpenRouter-hosted model
peekaboo agent "Check the current window" --model openrouter/xiaomi/mimo-v2.5-pro

# Explicitly authorize foreground/global UI for this new resumable session
peekaboo agent "Demonstrate the workflow visibly" --allow-foreground

# Dry-run the same task without executing any tools
peekaboo agent "Install the nightly build" --dry-run

# Resume the most recent session
peekaboo agent resume

# Resume one exact session from the full ID printed by `agent sessions`
peekaboo agent resume 12345678-1234-1234-1234-123456789abc

# List cached sessions as JSON
peekaboo agent sessions --json
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
