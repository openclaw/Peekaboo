---
summary: 'Review Peekaboo 3.0 System Specification guidance'
read_when:
  - 'planning work related to peekaboo 3.0 system specification'
  - 'debugging or extending features described here'
---

# Peekaboo 3.0 System Specification

**Status:** Living document · **Last updated:** 2025-11-14

Peekaboo 3.0 is the single automation stack powering the CLI, macOS app, agent runtime, and MCP integrations. This spec replaces older menu-bar-only drafts and captures the source-of-truth architecture reflected in the current codebase (`PeekabooAutomation`, `PeekabooAgentRuntime`, `PeekabooVisualizer`, CLI targets, and the Peekaboo.app bundle).

---

## 1. Vision & Scope

Peekaboo’s mission is to make macOS GUI automation as deterministic—and debuggable—as modern web automation. Key principles:

1. **CLI-first:** Every capability must be exposed through the `peekaboo` binary. Other surfaces (Peekaboo.app, agents, MCP) are thin shells over the same Swift services.
2. **Semantic interaction:** Commands operate on accessibility metadata (roles, labels, element IDs) instead of raw coordinates wherever possible.
3. **Visual transparency:** All interactions should be explainable via JSON output, logs, and annotated screenshots so humans/agents can reason about state.
4. **Reliability by default:** Commands autofocus windows (`FocusCommandOptions`), wait for actionable elements, and reuse sessions instead of forcing manual sleeps.
5. **Agent awareness:** Outputs are machine-friendly (`--json`), and behaviors are documented in `docs/commands/*.md` so autonomous clients receive the same guidance as humans.

**Scope:**
- CLI automation (`Apps/CLI`) built on `PeekabooCore` services.
- Peekaboo.app menu-bar UI + inspector/visualizer overlays.
- Agent runtime (Tachikoma + PeekabooAgentService) including `peekaboo agent` & MCP server (`peekaboo mcp`).
- Shared infrastructure such as session caching, configuration, permissions, and logging.

Not in scope: backwards compatibility with pre-3.0 CLIs, legacy argument parser usage, or duplicate menu-bar prototypes.

---

## 2. Product Surfaces

| Surface | Entry point | Purpose | Notes |
| --- | --- | --- | --- |
| CLI | `peekaboo …` | Primary automation surface with Commander-based command tree, JSON outputs, and agent-friendly logging. | Default actor is `@MainActor`. Commands live under `Apps/CLI/Sources/PeekabooCLI/Commands`. |
| Peekaboo.app | `Apps/Mac` | Menu-bar UI, permission onboarding, visualizer feedback, and inspector surfaces. Shares `PeekabooServices()` with CLI and registers defaults via `services.installAgentRuntimeDefaults()`. | Launch the app alongside the CLI binary during local development. |
| Visualizer | `PeekabooVisualizer` target | Animations, overlays, and progress indicators consumed by both CLI and app. | Communicates through the service layer (no direct AppKit glue inside commands). |
| Agent runtime | `PeekabooAgentRuntime` + Tachikoma | Implements `peekaboo agent`, GPT‑5/Sonnet integrations, dry-run planners, audio input, and MCP tools. | System prompt + tool descriptions live in `PeekabooAgentService.generateSystemPrompt()` and `create*Tool()` helpers. |
| MCP server | `peekaboo mcp` | Exposes native tools via Model Context Protocol. | Uses `PeekabooMCPServer`. |

---

## 3. Core Modules & Services

### 3.1 PeekabooAutomation (`Core/PeekabooCore/Sources/PeekabooAutomation`)
- Capture: `ScreenCaptureService`, `ImageCaptureBridge`, ScreenCaptureKit integration.
- Automation: `UIAutomationService`, `AutomationServiceBridge` for click/type/scroll/etc.
- Windows/Spaces/Menus/Dock/Dialog services with high-level bridges consumed by commands.
- Snapshot management: `SnapshotManager` (stores UI automation snapshots under `~/.peekaboo/snapshots/<snapshot-id>/`).

### 3.2 PeekabooAgentRuntime
- `PeekabooAgentService`: orchestrates tools, system prompt, MCP tool registry.
- `AgentDisplayTokens`: maps tool names to icons/text for progress output.
- Tachikoma integrations for GPT‑5, Claude, Grok, and Ollama. `--audio` and `--audio-file` transcribe input before running the agent; the non-functional `--realtime` flag was removed.

### 3.3 PeekabooVisualizer
- Animation + overlay payloads for CLI/app progress indicators.
- Receives structured events from `PeekabooServices` so both CLI and UI show the same feedback.

### 3.4 Command Runtime (`Apps/CLI/Sources/PeekabooCLI/Commands/Base`)
- `CommandRuntime` wires Commander parsing to the services layer.
- `InjectedRuntimeBackedCommand` owns the shared runtime/service/logger accessors; `RuntimeBackedCommand` adds `RuntimeOptionsConfigurable` fallback for commands that expose global options before runtime injection.
- Global options (verbose/log-level/json) are hydrated in `CommandRuntimeOptions`.
- `FocusCommandOptions` and `WindowIdentificationOptions` are reusable option groups; they map CLI flags to strongly typed structs used by automation services.

### 3.5 PeekabooServices lifecycle
```swift
@MainActor
let services = PeekabooServices()
services.installAgentRuntimeDefaults()
```
- Required in every surface that instantiates `PeekabooServices` directly (tests, custom daemons, etc.).
- Registers agent runtime defaults so MCP tools, CLI, and Peekaboo.app share the same service instances.
- CLI entry point (`PeekabooEntryPoint.swift`) creates a single `PeekabooServices` per process through `CommandRuntimeExecutor`.

---

## 4. Snapshot Lifecycle & Storage

1. **Creation:** `peekaboo see` captures the target, runs element detection, and writes a snapshot under `~/.peekaboo/snapshots/<snapshot-id>/` via `SnapshotManager` (`snapshot.json`, plus `raw.png` / `annotated.png` when available).
2. **Resolution:** Interaction commands call `services.snapshots.getMostRecentSnapshot()` when `--snapshot` is omitted. Coordinate-only commands skip snapshot usage entirely to avoid stale data.
3. **Reuse:** Commands that focus applications (`click`, `type`, etc.) merge snapshot info with explicit `--app` or `FocusCommandOptions` to bring the right window/Space forward before interacting.
4. **Cleanup:** `peekaboo clean` proxies into `services.files.clean*Snapshots` helpers. Users can delete all snapshots, those older than N hours, or a single snapshot ID; `--dry-run` reports would-be deletions without touching disk.

This shared cache is the hand-off mechanism between CLI invocations, custom scripts, and agents. Nothing else should read/write UI maps manually.

---

## 5. CLI Runtime Overview

- Commands are pure Swift structs conforming to `ParsableCommand` + optional protocols (`ApplicationResolvable`, `ErrorHandlingCommand`, `RuntimeOptionsConfigurable`).
- Commander metadata (`CommanderSignatureProviding`) replaces the previous ArgumentParser reflection and feeds both `peekaboo help` and `peekaboo learn`.
- Long-running or high-level commands (agents, MCP) still run on the main actor but hand heavy work to services that may hop threads internally.
- Every command documents its behavior in `docs/commands/<command>.md`. Use those docs for flag-level reference; this spec only covers architecture coupling.

Common helpers:
- `AutomationServiceBridge`: click/type/scroll/sleep wrappers that add waits and error hints.
- `ensureFocused(...)`: centralizes Space switching, retries, and no-auto-focus overrides.

---

## 6. Peekaboo.app & Visualizer

- SwiftUI menu-bar app housed in `Apps/Mac`. Maintains a long-lived `@State private var services = PeekabooServices()` and registers runtime defaults immediately.
- Presents permission onboarding, visualizer feedback, session activity, and inspector overlays. The removed realtime-voice surface is not part of the shipped app architecture.
- Shares `PeekabooServices` and configuration with the CLI. The app writes through OSLog while the CLI has its own stderr/JSON diagnostic logger.
- Visualizer target listens for events (captures, element highlights, agent step updates) and renders them both in the app and as CLI overlays when supported.

---

## 7. Agent Runtime & MCP

### 7.1 `peekaboo agent`
- Lives under `Apps/CLI/Sources/PeekabooCLI/Commands/AI/AgentCommand.swift`.
- Supports `agent run`, `agent resume [session-id]`, `agent sessions`, `agent chat`, `--dry-run`, `--max-steps`, `--no-cache`, and audio options.
- Output modes (`minimal`, `compact`, `enhanced`, `quiet`, `verbose`) adapt to terminal capabilities via `TerminalDetector`.
- Uses Tachikoma to call the GPT-5.6/5.5/5.4/5 families, Claude Opus 5/Fable 5/Sonnet 5 and compatible 4.x models, or Gemini 3.x. New configurations select GPT-5.6 and Opus 5; credential-only Anthropic discovery stays on Opus 4.8 for zero-retention compatibility. Session metadata stores the exact model selection for resume flows.

### 7.2 MCP (`peekaboo mcp`)
- `serve` starts `PeekabooMCPServer` over stdio/HTTP/SSE.
- `peekaboo mcp` defaults to `serve` so server startup does not require a subcommand.
- Native Peekaboo tools are registered via `MCPToolRegistry`.

---

## 8. Primary Workflows

1. **Capture → Act loop**
   - `see` generates snapshot files + annotated PNG (optional) and prints the `snapshot_id`.
   - Interaction commands automatically pick up the freshest snapshot (unless `--snapshot` overrides) and autofocus the relevant window.
   - Logs + JSON output include timings, UI bounds, and hints for debugging (e.g., element not found suggestions).

2. **Configuration & Permissions**
   - `peekaboo config` manages `~/.peekaboo/config.json` (JSONC), credentials, and custom AI providers. Commands directly call `ConfigurationManager` so the CLI/app read identical settings at startup.
   - `peekaboo permissions status|grant` uses `PermissionHelpers` to inspect/describe Screen Recording, Accessibility, Full Disk Access, etc. All automation commands should fail fast with actionable errors when permissions are missing.

3. **Automation Scripts & Agents**
   - `peekaboo agent` builds on top of those tools: it plans via GPT‑5/Sonnet, emits progress (Visualizer + stderr), and stores session history so users can resume or inspect steps. Agents always call the public CLI tools, so debugging any failure is as simple as rerunning the emitted sequence manually.

4. **MCP Server**
   - Running `peekaboo mcp` or `peekaboo mcp serve` lets Codex, Claude Code, Cursor, or MCP Inspector consume Peekaboo tools directly.

---

## 9. Future Work & Open Questions

- **Space/window telemetry:** continue refining `SpaceCommand` outputs so CLI/app/agent logs include explicit display + Space IDs for every focused window.
- **Right-button swipes:** `SwipeCommand` currently rejects `--right-button`; hooking that path up through `AutomationServiceBridge.swipe` is tracked separately.
- **Inspector unification:** Peekaboo.app, CLI overlays, and `docs/research/interaction-debugging.md` fixtures should share a single component catalog so new detectors (e.g., hidden web fields) land once and benefit all surfaces.

For flag-level behavior, troubleshooting steps, and real-world examples, refer to the per-command docs in `docs/commands/`. This spec focuses on how the pieces fit together; the command docs capture day-to-day usage.
