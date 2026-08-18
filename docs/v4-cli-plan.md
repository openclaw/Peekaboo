---
title: Peekaboo 4 CLI Redesign Plan
summary: 'Design principles, command map, flag grammar, tool-surface alignment, and phased implementation plan for the v4 CLI break.'
description: The v4 CLI redesign — what gets removed, merged, renamed, and why; phased PR plan and open questions.
read_when:
  - 'implementing or reviewing any v4 CLI surface change'
  - 'deciding whether a command or flag belongs in the v4 surface'
---

# Peekaboo 4 CLI Redesign Plan

Status: in implementation · 2026-08-09

This plan consolidates a full audit of the current CLI surface (40 root commands), the
MCP/agent tool catalog (28 MCP tools + 5 agent-only), and reference research: trycua/cua's
`cua-driver` (54-tool contract, RFCs), Anthropic `computer_20250124` / OpenAI CUA action
sets, xdotool/cliclick/adb grammars, vercel-labs/agent-browser, Playwright MCP,
mediar-ai/terminator, and clig.dev.

## 1. Design principles

**P1 — The complementarity razor.** Peekaboo assumes its caller has a shell. Any capability
a stock macOS tool already does well (`/usr/bin/open`, `/bin/sleep`, `pbcopy` for plain
text) is *out of scope for the CLI*. Peekaboo keeps only what the ambient CLI cannot do:
UI perception (element maps), focus-aware input synthesis, AX actions, window/space/menu/
dialog control, typed clipboard payloads, remote-bridge execution. The MCP surface may keep
a few extra tools (`sleep`, app `open` action) because MCP clients don't always have shell
access; the agent toolset already includes `shell` and needs no duplicates.

**P2 — One name table.** CLI command, MCP tool, agent tool, and docs share one canonical
name per operation, with a mechanical casing rule: tool `snake_case` ↔ CLI `kebab-case`
(the existing `ToolFiltering.normalize()` already treats `-`/`_` as equivalent). No more
`inspect_ui` tool vs `inspect-ui` CLI as a special case, no camelCase leaks in tool schemas
(`bundleId`, `filePath`, `dataBase64` → snake_case). cua proves the model: "the CLI
subcommand and the MCP tool run the same code path."

**P3 — Verbs flat, nouns nested.** The interaction primitives agents call constantly stay
root-level verbs (`click`, `type`, `press`, `scroll`, `move`, `drag`, `paste`, `see`) —
every model-facing action vocabulary (Anthropic, OpenAI, xdotool, agent-browser) is
verb-first, and fighting training-data priors costs accuracy. Everything else is a noun
namespace with uniform verbs (`app list`, `window focus`, `clipboard get`). Exactly one
way to do each thing: the root `list` umbrella dies.

**P4 — Borrow known grammars and declare the borrowing.** Where an established tool's
syntax is in every model's training data, adopt it verbatim and say so in help text:
`press` uses xdotool `key` chord syntax (`cmd+shift+t`, `Return`); durations accept
coreutils-style suffixes. One sentence of "same syntax as X" outperforms paragraphs of
bespoke docs.

**P5 — Ref-first, pixels explicit.** Element IDs from `see` are the primary addressing
mode (`--on B7`); coordinates are the explicit fallback (`--at 400,300`). Playwright MCP
gates xy-actions behind a suffix; we gate them behind a distinct flag and help-text
guidance.

**P6 — Unforgeable units.** All CLI duration/timeout flags accept suffixed values
(`500ms`, `2s`, `1.5s`); bare numbers mean milliseconds everywhere (matching current
interaction-flag behavior). Flag names drop unit suffixes (`--timeout`, not
`--timeout-seconds`). MCP tool params stay integer `*_ms` (cua convention; JSON has no
suffix strings).

**P7 — Machine-honest results.** `--json` output converges on one envelope and, once an
action request is parsed and classified, an `effect` field with a closed vocabulary
(see §6). Pre-dispatch action parse/bind failures report `effect: refused`. "The process exited 0"
must never silently stand in for "the click landed."

## 2. Command map: v4 surface

### Verbs (13)

| Command | Change vs v3 | Notes |
|---|---|---|
| `see` | absorbs `image` and `inspect-ui` | Adds `--format`, `--retina`, `--region x,y,w,h` (from `image`); `--tree`/`--depth`/`--max-elements` (from `inspect-ui`). `see --no-screenshot --tree` = old inspect-ui. cua precedent: perception is one operation returning both tree and pixels. |
| `capture` | drops `watch` alias | `capture live`, `capture video`, `capture action` only. |
| `click` | drops `--id` alias | `--on <id>` element, `--at <x,y>` coords (renames `--coords`), `--global` (renames `--global-coords`). |
| `type` | text-only | Drops `--return`, `--escape`, `--delete`, `--tab` (use `press`). Keeps `--clear`. |
| `press` | absorbs `hotkey` | xdotool `key` grammar with an exact background receipt or explicit foreground consent: `press cmd+c --snapshot <fresh-exact-snapshot>`, `press Return --count 3 --foreground`, `press cmd+shift+4 --foreground`. Help says "same syntax as xdotool key". |
| `scroll` | + OpenAI shape | Keeps `--direction/--amount`; adds `--dx/--dy` delta form so both Anthropic- and OpenAI-trained agents emit valid calls first try. |
| `move` | flag cleanup | `--at <x,y>` / `--on <id>`; drops `--id` alias. |
| `drag` | absorbs `swipe` | `--from` / `--to` each accept element ID *or* `x,y` (pattern-disambiguated; IDs never contain commas). Drops `--from-coords`/`--to-coords`. `--no-drop` covers swipe-without-drop if implementations truly differ (verify during implementation; else `swipe` just dies). |
| `paste` | unchanged shape | Shares payload flags with `clipboard set` exactly; drops `--image-path` alias. |
| `set-value` | + targeting group | Gains `--app`/`--window-*` targeting like its siblings. Tool: `set_value`. |
| `action` | renamed from `perform-action` | `peekaboo action AXShowMenu --on B7`. Tool renamed `perform_action` → `action`. (Alternative considered: cua folds AX actions into `click --action`; rejected because `AXIncrement` on a slider is not a click.) |
| `verify` | new (exposes existing tool) | CLI for the already-shipped `verify_state` MCP tool: predicates, `--timeout`, `--stable-samples`, ternary result. This is the principled replacement for blind sleeps. |
| `open` → **removed** | | `/usr/bin/open` (P1). Ready-wait moves to `app launch --wait-ready`. |

### Nouns (9)

| Namespace | Subcommands | Change vs v3 |
|---|---|---|
| `app` | `list`, `launch`, `quit`, `relaunch`, `hide`, `unhide`, `switch`, `focus` | + `focus` (tool has it, CLI lacked it). `launch` gains `--wait-ready` and URL/file targets (from `open`). |
| `window` | `list`, `focus`, `move`, `resize`, `set-bounds`, `close`, `minimize`, `maximize`, `restore` | + `restore` (tool parity). `window` tool gains `list` action (currently only in the `list` tool). |
| `screen` | `list` | Root `list screens` dies. |
| `menu` | `list`, `click` | Drops `click-extra`, `list-all` (menubar's job). |
| `menubar` | `list`, `click` | Converted from positional `<action>` to real subcommands. |
| `dock` | `list`, `launch`, `right-click`, `show`, `hide` | unchanged |
| `dialog` | `list`, `click`, `input`, `file`, `dismiss` | unchanged |
| `space` | `list`, `switch`, `move-window` | unchanged |
| `clipboard` | `get`, `set`, `clear`, `save`, `restore` | Real subcommands; drops `-a/--action`, drops `load` (= `set --file`), drops `--image-path` alias. Passes the razor: UTI-typed payloads, cross-invocation slots (named NSPasteboards), `--verify`, remote bridge — none of which pbcopy can do. |

### Management (10)

| Command | Change vs v3 |
|---|---|
| `agent` | Mode flags become subcommands: `agent [run] "task"` (default), `agent resume [id]`, `agent sessions`, `agent chat`. `agent permission` subtree dies (merged into root `permissions`). |
| `mcp` | `serve` (default). Unchanged. |
| `config` | Restructured: `init`/`show`/`edit`/`validate`/`status` + `config provider add|remove|list|test|models` + `config credential set` / `config login`. Replaces the 13 flat subcommands (`add-provider`, `models-provider`, `set-credential`, …). |
| `permissions` | Merged tree: `status` (default), `grant`, `request accessibility|screen-recording|event-synthesizing`. Absorbs `agent permission` (which had `request-accessibility`; root didn't). |
| `daemon` | `status` (default), `start`, `stop`, `run`. Unchanged. |
| `bridge` | `status` (default). Unchanged. |
| `tools` | Keeps catalog listing; **adds `tools describe <name>`** (cua's `describe` — per-tool schema on demand, the token-cheap discoverability lever). |
| `learn` | Unchanged (agent usage guide). Regenerate content from the new surface. |
| `clean` | Unchanged (snapshot cache is Peekaboo-owned state). |
| `completions` | Unchanged; renderers pick up the registry automatically. |
| `browser` | Kept at root (Chrome control is not shell-duplicable). Re-described as a first-class command — drop "through the browser MCP tool" phrasing. |

### Removed outright (10 root commands)

`image`, `list`, `sleep`, `open`, `run`, `hotkey`, `swipe`, `perform-action` (renamed),
`inspect-ui` (merged), `commander`. Net: **40 → exactly 33 root entries**, and every survivor
passes the razor.

- `sleep` — P1. `/bin/sleep` exists; the ms-argument variant actively conflicts with shell
  habits. MCP `sleep` tool stays (MCP clients may lack shell).
- `open` — P1. See `app launch`.
- `run` — P1 + maintenance. It is a third parallel dispatch switch (13 commands, own
  camelCase param dialect) that exists only because it predates "the agent has bash." A
  shell script chaining `peekaboo` commands is the automation script. Delete
  `ProcessService.executeStep` script dispatch, `RunCommand`, `docs/commands/run.md`.
- `commander` — dev diagnostics; delete from the public registry (revive behind a hidden
  `debug` group only if Commander gains `hidden` support later).
- `visualizer` — **kept**: it exercises Peekaboo's visual-feedback overlays (nothing the
  shell can do) and is the test harness for the v4 visualizer redesign (§9).

## 3. Uniform flag grammar

Shared option groups, identical names and semantics everywhere they appear
(terminator-style "composable parameter groups"; today's `InteractionTargetOptions` /
`FocusCommandOptions` become the enforced contract):

- **Target**: `--app <name|bundle-id|PID:n>`, `--pid`, `--window-title`, `--window-index`,
  `--window-id` (unchanged — already consistent).
- **Address**: `--on <element-id>` (primary) · `--at <x,y>` (explicit coordinate fallback)
  · `--from`/`--to` (dual-typed on drag). `--snapshot <id|latest>` (unchanged).
- **Timing**: `--timeout`, `--delay`, `--duration`, `--hold`, `--wait-for` — all accept
  `Nms`/`Ns` suffixes, bare = ms (P6). Kills `--timeout-seconds`,
  `--focus-timeout-seconds` → `--focus-timeout`, `--restore-delay-ms` → `--restore-delay`,
  `--hold-duration` → `--hold`.
- **Focus**: `--foreground`, `--focus-background`, `--no-auto-focus`, `--space-switch`,
  `--bring-to-current-space` (unchanged names, applied uniformly — click/hotkey have
  `--focus-background` today, type/scroll don't; make the matrix deliberate).
- **Global**: `--json/-j`, `--verbose/-v`, `--log-level`, `--no-remote`,
  `--bridge-socket`, `--input-strategy`. Drop the `--json-output` legacy alias.
- **Modifiers**: list-valued `--modifiers cmd,shift` (OpenAI/Playwright style), never a
  stringly overloaded field.
- **Multi-shape parameters are a feature, not a smell.** Where major agent APIs disagree
  on shape (Anthropic `--direction/--amount` vs OpenAI `--dx/--dy` scroll; element-ID vs
  coordinate addressing), accept both shapes and document both in help text — the goal is
  that whatever an agent was trained to emit is already valid. Each shape pair must be
  mutually exclusive per invocation with a clear error naming the other shape.

## 4. Tool-surface alignment (MCP + agent)

1. **Renames in lockstep with CLI**: `perform_action` → `action`; `inspect_ui` merges
   into `see`; `image` tool merges into `see`/`capture` (tool side keeps `image` only if
   screenshot-without-elements needs to stay cheap — decide during implementation;
   default: keep one `see` with `--no-elements`-equivalent param).
2. **Schema hygiene**: fix camelCase leaks (`AppTool`: `bundleId`, `openTargets`,
   `waitUntilReady`, `waitForWindow`, `newInstance`; `ClipboardTool`: `filePath`,
   `imagePath`, `dataBase64`) → snake_case.
3. **Consolidation** (Anthropic tool-writing guidance): kill the `list` MCP tool; `app`
   gains/keeps `list`, `window` gains `list`. Kill agent-only legacy shims `list_apps`,
   `list_screens` (broken enum value today), `launch_app`.
4. **The five hard-coded name tables** that must move together with any rename:
   - `MCPToolSnapshotMutationPolicy.effect(toolName:arguments:)`
     (`MCP/MCPToolSnapshotMutation.swift:190`) — **the dangerous one**: a missed rename
     silently degrades to `.none` (no snapshot invalidation). Add a test asserting every
     catalog tool name has an explicit policy entry (no `default:` fallthrough for known
     tools).
   - `ToolType` (`ToolFormatting/ToolType.swift`) — add new raw values, keep old ones
     (established precedent for persisted-session formatting).
   - `AgentSystemPrompt.swift` — prose tool names.
   - `ToolRegistry.convertAgentToolToDefinition` — stale category switch; rebuild from
     the catalog instead of a parallel hard-coded switch.
   - `skills/peekaboo/SKILL.md` + `docs/commands/*.md` + `docs/cli-command-reference.md`
     + `docs/MCP.md`.
5. **Dead code deletion**: `ToolDefinitions.swift` (unreferenced), the non-compiling
   `AgentToolsTests.swift`, the `list` tool's `server_status` item type (fold into
   `bridge`/`daemon` status if still needed).

## 5. Breaking-change policy

Clean break at 4.0 — no root-command aliases, no hidden compat commands (Commander has no
alias/hidden support and we deliberately don't add it for this). Rationale: agents re-read
help every session and carry no muscle memory; the alias window that clig.dev recommends
for humans buys little here and costs namespace hygiene. Mitigations instead:

- `docs/v4-migration.md`: complete old → new table (every removed command/flag with its
  replacement, including "use `/bin/sleep`" / "use `/usr/bin/open`" rows).
- Changelog entry per removal.
- `ToolType` keeps old raw values so persisted agent sessions still format.
- The `run`-script format dies with `run`; no `.peekaboo.json` compat layer (the format
  was never a stable public contract — confirm no external consumers before deleting).

## 6. Result envelope (phase-able, recommended for 4.0)

Adopt cua's closed result vocabulary in `--json` output for parsed and classified action requests:

```json
{ "success": true,
  "effect": "confirmed | partial | unverifiable | suspected_noop | refused",
  "data": { ... },
  "error": { "code": "...", "message": "...", "hint": "Run 'peekaboo see' to refresh." } }
```

- `effect` is computed from existing verification machinery (click focus-verification,
  window geometry readback, clipboard `--verify`) — the plumbing largely exists; v4 makes
  it a contract.
- Commander parse/bind failures for recognized action commands report `effect: refused`;
  they still use the standard error envelope and a nonzero exit.
- Errors carry actionable hints, not just codes (Anthropic tool-writing guidance).
- Non-zero exit iff `success == false`. Deprecation/warning text goes to stderr only.

## 7. Implementation phases

Each phase is an independently landable PR with tests + docs; order minimizes rebase pain.

1. **P1 Removals** — delete `sleep`, `open`, `run` (+ ProcessService script dispatch),
   `commander`, `visualizer`, root `list`, `capture watch`, `menu click-extra|list-all`,
   `agent permission` subtree, legacy aliases (`--json-output`, `--id`, `--image-path`,
   `--app-target`), agent shims (`list_apps`, `list_screens`, `launch_app`), MCP `list`
   tool (+ `window list` action added first). Update the five name tables + docs.
2. **P2 Restructures** — `clipboard` and `menubar` to real subcommands; `config`
   provider/credential namespaces; `agent` subcommands; `permissions` merge (+
   `request accessibility`); `app focus`, `window restore`, `app launch --wait-ready`.
3. **P3 Merges** — `hotkey`→`press` (xdotool grammar), `swipe`→`drag`,
   `image`→`see`/`capture`, `inspect-ui`→`see`, `perform-action`→`action`. Tool renames +
   name-table lockstep + snapshot-mutation-policy test.
4. **P4 Flag grammar** — timing suffixes, `--at`, dual-typed `--from/--to`, `--modifiers`
   lists, focus-flag matrix, shared option groups enforced.
5. **P5 New capability** — `verify` CLI command, `tools describe <name>`, regenerate
   `learn` content.
6. **P6 Result envelope** — §6, plus JSON-shape tests per command.

Post-4.0 candidates (explicitly out of scope): batch/stdin mode (process-cost
amortization — daemon already mitigates; revisit with data), capability-profiled MCP
(`mcp serve --tools core|all`, Playwright-style), `--max-output`/`--detail` knobs on
`see`, session naming (`--session`/env pairing, agent-browser-style).

## 8. Visualizer redesign (parallel track)

Current state: 14 animation types in `Core/PeekabooVisualizer` (click, type, scroll,
hotkey, swipe path, mouse trail, window op, dialog, menu navigation, space transition,
app launch/quit, screenshot flash, watch HUD, element highlight). Most are global
full-screen overlays; the sum is noisy. v4 direction: **fewer, quieter, app-anchored.**

**Keep (redesigned):**

1. **Agent cursor** — the flagship. When Peekaboo drives the mouse, show a distinct
   cursor overlay moving *naturally* (eased path, cua-style arc/glide) to the target,
   with a subtle pulse on click. Drag/swipe render as the same cursor in a pressed state
   following the path — `SwipePathView` and `MouseTrailView` fold into this.
2. **Input HUD anchored to the eligible foreground target window** —
   keystrokes/chords/typed text appear in a small chip pinned to the window's bottom edge
   (clipped to its frame), not a global overlay. Targeted background input emits no HUD
   event even when that target is visible or frontmost. Replaces the full-screen
   `HotkeyOverlayView` and `TypeAnimationView`. Eligible foreground scroll feedback
   becomes a micro-badge in the same HUD.
3. **Element annotation** (`see --annotate`, inspector) — functional, keep as is.
4. **Capture indicators** — screenshot flash reduced to a brief thin border around the
   captured region; `capture live` recording HUD stays (privacy-relevant).

**Remove:** `AppLifecycleView` (launch/quit icon zoom), `SpaceTransitionView`,
`MenuNavigationView`, `DialogInteractionView`, `WindowOperationView` as standalone
animations; their events either map to the agent cursor (they involve foreground pointer
movement) or show nothing. Per-animation switches collapse into three feedback categories:
agent cursor, input HUD, and capture indicators. The UI still has a visualizer master
switch, a separate menu-bar app-icons switch, and animation speed/intensity controls.

**Architectural change:** the feedback API gains target-window context, but delivery mode
remains the first gate. The interaction layer drops every targeted background-input
feedback event before it reaches `VisualizerAutomationFeedbackClient`, regardless of the
target's current visibility or frontmost state. For eligible foreground feedback, the
client passes `(pid, windowID, windowFrame)` and the renderer revalidates that the window
is still visible before presenting an anchored HUD. This keeps background work invisible
without relying on a timing-sensitive visibility test.

## 9. Open questions (decide before P3)

1. `image` as a *tool* (not CLI): keep a cheap screenshot-only tool for MCP clients, or
   one `see` with an elements toggle? (CLI side is decided: `see` only.)
2. `swipe` vs `drag`: confirm the implementations are mergeable (right-button swipe,
   no-drop semantics) — if genuinely distinct, keep `drag --no-drop` spelling anyway.
3. `verify` naming: `verify` (matches tool, honest ternary semantics) vs `wait`
   (training-data prior from browser_wait_for). Recommendation: `verify`, with `--timeout`
   giving it wait-for semantics; mention "replaces sleep-polling" in help.
4. Does anything external consume `.peekaboo.json` scripts? (Determines whether `run`
   removal needs a deprecation release first.)
5. `menubar` naming: keep `menubar`, or rename to `statusbar`/`status-item` to end the
   `menu`/`menubar` confusion? Recommendation: keep `menubar` (macOS-native term).
