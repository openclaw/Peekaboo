---
summary: 'Document the minimal interactive chat loop for peekaboo agent'
read_when:
  - 'planning work related to the agent chat loop'
  - 'debugging or extending the interactive agent shell'
---

# Minimal Agent Chat Mode

This document captures the initial design for a dependency-free interactive chat shell built on top of `peekaboo agent`. The goal is to let operators hold a live conversation—enter a prompt, let the agent act, then immediately enter another prompt—without reinventing the retired TermKit UI.

## How You Enter Chat Mode

- `peekaboo agent "<task>"` keeps the existing single-shot behavior.
- Running `peekaboo agent` **without** a task drops you into chat mode automatically when stdout is an interactive TTY.
- In non-interactive environments the command prints the chat help menu and exits, except a taskless
  `--resume` / `--resume-session`, which consumes piped prompts for the saved session.
- `--chat` always forces the interactive loop (even when piped) and doubles as the discoverable/explicit switch for documentation and tooling.
  - If you pass a task alongside `--chat`, that text becomes the first turn before the prompt reappears.

## Command Surface

- Introduce a `--chat` flag on `peekaboo agent`.
- When present, the command enters an interactive loop instead of executing once and exiting.
- All existing options (`--model`, `--max-steps`, `--resume-session`, `--no-cache`, etc.) still apply at launch; their values remain in effect for the entire chat session.

## Session Lifecycle

1. Starting the chat loop either resumes an explicit session (`--resume-session <id>`), resumes the most recent session when `--resume` is supplied, or creates a fresh one.
2. The resolved session ID is reused for every turn so the agent maintains context.
3. Exiting the loop leaves the session in the cache so the standard `agent` command can resume it later.

## Control Flow

```text
peekaboo agent --chat
→ print header (model, session ID, exit instructions)
loop {
    prompt with `chat> `
    read a line from stdin (skip empty lines)
    run the existing agent pipeline with that line as the task text
    display the usual transcript (enhanced/compact/minimal) until completion
}
```

- `readLine()` is sufficient for v1; pasted multi-line text will arrive line-by-line but still accumulate because each line triggers a run.
- When the loop opens it prints “Type /help for chat commands” and immediately dumps the `/help` menu so operators know what to expect.
- `/help` can be entered at any time to reprint the built-in menu.
- End-of-file (Ctrl+D) or a SIGINT while idle breaks out of the loop. Ctrl+C while a task is running cancels that turn and returns to the prompt.
- Press `Esc` during an active turn to cancel the in-flight run immediately and return to the prompt.

## Prompt & Output

- Display a simple ASCII prompt: `chat> `.
- After each turn, optionally print a one-line summary (model, duration, tool count) before reprinting the prompt. This avoids repeating the full banner every time.
- `Type /help …` banner plus the help menu are shown automatically the moment interactive mode starts, even before the first task (or immediately after running the optional seeded task supplied with `--chat`).
- Reuse the existing output-mode machinery so enhanced/compact/minimal renderings continue to work automatically.

## Error Handling

- Failed executions (missing credentials, tool errors, etc.) bubble through the current `displayResult` / error printers so behavior matches the one-shot command. An automatic taskless piped resume exits nonzero after a failed turn; an explicit interactive `--chat` loop stays alive.
- If the agent reports a fatal error, the loop stays alive unless the error indicates initialization failure (e.g., no provider configured), in which case we exit immediately.

## Exit Semantics

- Ctrl+C while idle → exit the loop cleanly.
- Ctrl+C while running → cancel the active task and return to the prompt (press again to exit entirely if desired).
- Ctrl+D (EOF) → exit after the current prompt.
- Non-interactive invocations without `--chat` print the help text once and exit, except taskless session resumes,
  which read piped prompts and exit nonzero after a failed turn.

## Future Enhancements (Out of Scope for Minimal Version)

- Slash commands (`/model`, `/stats`, `/clear`).
- Multi-line paste blocks (triple quotes) or heredoc-style delimiters.
- Richer terminal UI (colors in the prompt, live tool streaming columns, etc.).
- Dedicated transcript panes or scrolling history.

The minimal design above provides a usable chat workflow immediately while keeping the implementation lean enough to land incrementally.
