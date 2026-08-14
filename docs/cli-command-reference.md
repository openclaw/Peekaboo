---
summary: 'Cheat sheet for every Peekaboo CLI command grouped by category.'
read_when:
  - 'learning what each CLI subcommand does'
  - 'mapping agent tools to direct CLI usage'
---

# CLI Command Reference

This source-tree reference covers all 33 root commands in the upcoming v4 registry and is checked against the built binary's `--help` output. Use `peekaboo <command> --help` for every option and `peekaboo tools` for the separate MCP/agent tool catalog.

## Core commands

| Command | Purpose / subcommands |
| --- | --- |
| [`bridge`](commands/bridge.md) | Inspect Bridge connectivity; `status` is the default subcommand. |
| [`capture`](commands/capture.md) | `action`, `live`, and `video` capture workflows. |
| [`clean`](commands/clean.md) | Remove snapshot cache data, with `--dry-run` support. |
| [`completions`](commands/completions.md) | Generate zsh, bash, or fish completion scripts. |
| [`config`](commands/config.md) | Configuration plus `credential` and `provider` subcommand trees. |
| [`daemon`](commands/daemon.md) | `run`, `start`, `status`, and `stop` the headless daemon. |
| [`learn`](commands/learn.md) | Print the agent guide, tool catalog, and live command signatures. |
| [`permissions`](commands/permissions.md) | `status`, `grant`, or `request <kind>`. |
| [`screen`](commands/screen.md) | `list` connected displays. |
| [`tools`](commands/tools.md) | `list` MCP tools or `describe <name>` for one schema. |

## Interaction commands

| Command | Purpose |
| --- | --- |
| [`action`](commands/action.md) | Invoke a named accessibility action. |
| [`click`](commands/click.md) | Click an element/query or `--at x,y`. |
| [`drag`](commands/drag.md) | Drag between element IDs or coordinates using `--from` and `--to`. |
| [`move`](commands/move.md) | Move the physical pointer to `--on` or `--at`. |
| [`paste`](commands/paste.md) | Paste current clipboard content or atomically set, paste, and restore. |
| [`press`](commands/press.md) | Press xdotool-style chords or chord sequences. |
| [`scroll`](commands/scroll.md) | Scroll by direction, optionally on an element. |
| [`set-value`](commands/set-value.md) | Set an accessibility element value directly. |
| [`type`](commands/type.md) | Type text; standalone keys and chords belong to `press`. |

## System commands

| Command | Purpose / subcommands |
| --- | --- |
| [`app`](commands/app.md) | `focus`, `hide`, `launch`, `list`, `quit`, `relaunch`, `switch`, and `unhide`. |
| [`clipboard`](commands/clipboard.md) | `get`, `set`, `clear`, `save`, and `restore`. |
| [`dialog`](commands/dialog.md) | `click`, `dismiss`, `file`, `input`, and `list`. |
| [`dock`](commands/dock.md) | `hide`, `launch`, `list`, `right-click`, and `show`. |
| [`menu`](commands/menu.md) | `click` or `list` application menus. |
| [`menubar`](commands/menubar.md) | `click` or `list` menu-bar status items. |
| [`space`](commands/space.md) | `list`, `move-window`, and `switch` Spaces. |
| [`visualizer`](commands/visualizer.md) | Exercise the agent cursor, input HUD, and capture indicators. |
| [`window`](commands/window.md) | `close`, `focus`, `list`, `maximize`, `minimize`, `move`, `resize`, `restore`, and `set-bounds`. |

## Vision, AI, and MCP commands

| Command | Purpose / subcommands |
| --- | --- |
| [`see`](commands/see.md) | Capture pixels and element maps; use `--tree`, `--no-screenshot`, or `--no-elements` to select the observation shape. |
| [`verify`](commands/verify.md) | Poll stable window/element predicates; results are satisfied, unsatisfied, or unknown. |
| [`agent`](commands/agent.md) | `run`, `resume`, `sessions`, and `chat`; `run` is the default. |
| [`browser`](commands/browser.md) | Control Chrome page content through the browser MCP tool. |
| [`mcp`](commands/mcp.md) | Start the MCP server; `serve` is the default subcommand. |

## Shared grammar

Durations accept bare milliseconds, `ms`, or `s`: `500`, `500ms`, `2s`, and `1.5s` are equivalent forms. Coordinate input is `--at x,y`; with an app/window target it is target-relative unless `--global` is present. Modifier lists use comma-separated values such as `cmd,shift`.

Interaction commands share foreground/focus controls where relevant. Background delivery is the default when Peekaboo can resolve an exact process target; physical pointer gestures and intentional global input require `--foreground`.

## JSON result envelope

Pass `--json` (or the Commander-provided `--json-output` alias) for one stable result shape. Every response has `success`, `data` (null when unavailable), optional `error`, and `debug_logs`. Failed responses exit nonzero and include `error.code`, `error.message`, and an actionable `error.hint` when the command already knows the next step.

Once the command path identifies an action request, its result also includes a top-level `effect`: `confirmed` when existing AX/readback verification proves the result, `partial` for a partly completed multi-step action, `unverifiable` when input was dispatched without an application-level signal, `suspected_noop` when a post-check found no change, or `refused` when a safety gate prevented dispatch. Commander parse/bind failures for recognized action commands report `effect: refused`; read-only commands omit `effect`. MCP action tools expose the same canonical fields in result metadata.

When an interaction, window mutation, or application lifecycle command returns a native action receipt, JSON also includes a top-level `outcome` object. This includes click, type, scroll, `press`, `action`, `set-value`, background window geometry/lifecycle operations, and application launch, relaunch, quit, hide, unhide, focus, and switch. The object is the validated canonical projection: state, route, delivery, evidence, dispatch state/count, retry safety, escalation, refusal reason, and the derived `mutation_dispatched`, `retry_safe`, and `requires_fresh_observation` compatibility fields. The legacy top-level `effect` and failure safety fields derive from that same object. Read-only commands, older hosts, and actions without native receipts omit `outcome` rather than fabricating a receipt.
