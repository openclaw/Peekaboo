---
summary: 'Completion audit for the UI input action-first refactor plan.'
read_when:
  - 'checking whether docs/refactor/ui-input-action-first.md is implemented'
  - 'planning default flips for click, scroll, type, or hotkey'
  - 'reviewing action-first test coverage and rollout blockers'
---

# UI Input Action-First Audit

## Objective

Complete the refactor described in `docs/refactor/ui-input-action-first.md`: make UI input dual-mode with
accessibility action invocation first where configured, synthetic input as fallback, preserved element intent through
MCP/CLI/bridge layers, debug-visible path selection, and tests proving current behavior remains safe under `synthFirst`.

## Current Status

Implementation status: **complete for the requested refactor scope**.

The action-first architecture is in place, click and scroll now use the Phase 3 `actionFirst` built-in defaults, and
the unit/safe test gates pass locally. The first guarded Playground matrix has proven the core action-first click,
direct value, menu-hotkey, and scroll fallback paths.

There is intentionally no telemetry subsystem. For OSS, persistent UI automation metrics are mostly maintenance and
privacy cost without useful aggregate signal. Diagnostics stay explicit: command results, debug logs, targeted tests,
and user-provided repro artifacts.

Type and generic hotkey defaults intentionally stay conservative: direct value setting is the action-first typing path,
and menu-bound hotkeys have an action path with synthetic fallback/per-app overrides.

## Completion Decision

As of 2026-05-08, the refactor is complete for the implemented action-first scope.

Concrete success criteria from the plan:

- dual-mode action/synth architecture with injectable drivers and policy resolution
- MCP/CLI/bridge paths preserve element intent and expose `set_value` / `perform_action`
- click and scroll run `actionFirst` by default with fallback metadata
- type keeps normal synthesized typing while exposing direct action/value setting through `set_value`
- hotkey keeps normal synthesized chords while exposing menu-item action invocation with fallback and per-app overrides
- dispatcher behavior is covered by targeted tests and debug-visible execution results
- current safe gates and targeted refactor tests pass

No remaining item blocks completion.

## Checklist

| Requirement | Evidence | Status |
|---|---|---|
| Product-neutral strategy names: `actionFirst`, `synthFirst`, `actionOnly`, `synthOnly` | `Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Strategy/UIInputStrategy.swift` | Done |
| Policy model with default, per-verb, and per-app strategy | `UIInputPolicy.swift`; `ConfigurationManager+Accessors.swift`; `InputConfigTests` | Done |
| CLI/env/config strategy resolution with CLI precedence | `CommandRuntime.swift`; `ConfigurationManager+Accessors.swift`; `InputConfigTests` | Done |
| Phase 3 built-in click/scroll defaults | `UIInputPolicy.currentBehavior`; `ConfigurationManager+Accessors.swift`; `InputConfigTests` | Done |
| Execution metadata type | `UIInputExecutionResult` in `UIInputPolicy.swift` | Done |
| Dispatcher fallback only for unsupported action-surface gaps | `UIInputDispatcher.swift`; `UIInputDispatcherTests` | Done |
| Every fallback-eligible action gap maps to synthetic fallback | `UIInputDispatcherTests` covers `actionUnsupported`, `attributeUnsupported`, `valueNotSettable`, `secureValueNotAllowed`, `menuShortcutUnavailable`, and `missingElement` | Done |
| No silent fallback on stale element, permission denied, or target unavailable | `UIInputDispatcher.swift`; `UIInputDispatcherTests` | Done |
| Debug path logs and execution metadata replace telemetry | `UIInputDispatcher.swift`; `UIInputExecutionResult` | Done |
| No telemetry command, env vars, disk store, or session tracker | Deleted telemetry command/docs/Foundation store/session tests | Done |
| Injectable action driver | `ActionInputDriver.swift`; injected through services and tests | Done |
| Injectable synthetic driver | `SyntheticInputDriver.swift`; injected through click/scroll/type services and covered by `SyntheticInputDriverTests` | Done |
| Element wrapper with role/name/value/actions/settable/focused/enabled/offscreen | `AutomationElement.swift` | Done |
| Mockable element seam for action-driver tests | `AutomationElementRepresenting`; `MockAutomationElement` tests in `ActionInputDriverTests` | Done |
| Fresh element resolver from snapshot/query/window context | `AutomationElementResolver.swift` | Done |
| Do not persist raw AX handles in snapshots | Action driver resolves from serialized snapshot data at action time | Done |
| Click action path with `AXPress`, right-click `AXShowMenu`, double-click unsupported | `ActionInputDriver.swift`; `ClickService.swift` | Done |
| Click synthetic fallback preserved | `ClickService.swift`; current safe tests pass under `synthFirst` | Done |
| Click visualizer anchor uses action result midpoint when available | `UIAutomationService+Operations.swift`; `ActionInputResult.anchorPoint` | Done |
| Scroll action path with conservative AX page actions | `ActionInputDriver.swift`; `ScrollService.swift` | Done |
| Scroll synthetic fallback preserved | `ScrollService.swift`; current safe tests pass under `synthFirst`; live targeted scroll fallback proof | Done |
| Scroll action-mode visualizer avoids mouse location when anchor exists | `UIAutomationService+PointerKeyboardOperations.swift` uses `result.anchorPoint` before `NSEvent.mouseLocation` | Done |
| Type action path only for replace/direct-set semantics | `TypeService.swift`; `ActionInputDriver.trySetText` rejects non-replace | Done |
| `typeActions` remains synthesis-backed | `TypeService.typeActions` passes `action: nil` | Done |
| Direct value setter tool | `SetValueTool.swift`; `SetValueCommand.swift`; bridge setValue support | Done |
| Secure/password direct set rejected by default | `ActionInputDriver.setValueRejectionReason`; `ActionInputDriverTests` | Done |
| Generic action invoker tool | `PerformActionTool.swift`; `PerformActionCommand.swift`; bridge performAction support | Done |
| Unsupported arbitrary action reports advertised action names | `UIAutomationService+ElementActions.swift`; `ActionInputDriverTests` | Done |
| Hotkey action path via menu item resolution | `ActionInputDriver.tryHotkey`; `HotkeyService.swift`; `HotkeyServiceTargetingTests`; live Playground menu action proof | Done |
| Hotkey fallback for non-menu shortcuts | `HotkeyServiceTargetingTests` | Done |
| Per-app hotkey override support | `UIInputPolicy`; `Configuration.swift`; `InputConfigTests` | Done |
| Drag/swipe/move stay synthesis-only | No action strategy added for those verbs | Done |
| MCP `ClickTool` preserves element ID intent | `ClickTool.swift`; `MCPToolExecutionTests` | Done |
| MCP `TypeTool` preserves element target for focus click | `TypeTool.swift`; `MCPToolExecutionTests` | Done |
| MCP `ScrollTool` preserves element target | `ScrollTool.swift` | Done |
| MCP hides action-only tools when action invocation disabled | `ToolFiltering.swift`; `ToolFilteringTests`; `PeekabooMCPServer.swift` | Done |
| MCP/agent prompt guardrails prefer fresh `see` and element targets | `AgentSystemPrompt.swift`; `docs/MCP.md` | Done |
| Mutating MCP actions invalidate active snapshot | `ClickTool`, `TypeTool`, `ScrollTool`, `SetValueTool`, `PerformActionTool` | Done |
| Explicit missing action snapshot fails as stale before fallback | `ClickService`, `ScrollService`, `TypeService`; target-resolution tests | Done |
| Turn-scoped forced refresh after every perceive→act cycle | Mutating MCP tools invalidate active snapshots; agent turn-boundary tests | Done |
| Bridge operations for setValue/performAction | `PeekabooBridge*` files; `PeekabooBridgeTests` | Done |
| Bridge protocol minor bump | `PeekabooBridgeConstants.protocolVersion == 1.3` | Done |
| Version mismatch asks user/model to relaunch host app | `PeekabooBridgeServer+Handshake.swift`; `PeekabooBridgeTests` | Done |
| Docs for config and tools | `docs/configuration.md`; `docs/MCP.md`; `docs/commands/set-value.md`; `docs/commands/perform-action.md` | Done |
| Unit tests listed in the plan | `InputConfigTests`, `UIInputDispatcherTests`, `ActionInputDriverTests`, MCP/bridge tests | Done |
| Input automation cannot type into arbitrary active apps by accident | `InputAutomationSafety` frontmost bundle allow-list; `InputAutomationSafetyTests` | Done |
| GUI automation: AXPress native button | `.artifacts/ui-input-action-first/20260508-014638/action-click.json`; `click.log` confirms the Playground button action fired | Done |
| GUI automation: direct value set text field | `.artifacts/ui-input-action-first/20260508-014638/action-set-value-live.json`; `see-text-after-setvalue.json` confirms `basic-text-field` label changed to `action value 20260508 live` | Done |
| GUI automation: menu-item hotkey invocation | `.artifacts/ui-input-action-first/20260508-014638/action-hotkey-menu-fixed.json`; `menu.log` confirms `Test Action 1 clicked` | Done |
| GUI automation: scroll fallback path | `.artifacts/ui-input-action-first/20260508-014638/action-scroll-target-fixed.json`; `scroll-fixed.log` confirms offset changes | Done |
| GUI automation: visualizer anchor for action click | `UIAutomationServiceVisualizerTests` proves action anchor wins over coordinate fallback | Done |
| Phase 5 type/hotkey default flip | Deferred by design; normal `type`/generic `hotkey` stay conservative, while `set_value` and menu-bound hotkey action paths cover the action-first use cases | Deferred |
| `synthOnly` escape hatch | Strategy/config implemented; tests cover synth-only dispatch | Done |

## Verified Locally

Last known passing local gates before removing telemetry:

```text
swift test --package-path Core/PeekabooAutomationKit --no-parallel
swift test --package-path Core/PeekabooCore --filter "AgentTurnBoundaryTests|MCPToolExecutionTests|ToolFilteringTests|MCPToolRegistryTests|MCPSpecificToolTests|PeekabooBridgeTests|InputConfigTests" --no-parallel
pnpm run test:safe
pnpm run lint
pnpm run lint:docs
pnpm run format
git diff --check
```

After removing telemetry, rerun at minimum:

```text
swift test --package-path Core/PeekabooAutomationKit --filter "UIInputDispatcherTests|ActionInputDriverTests|ClickServiceTargetResolutionTests|ScrollServiceTargetResolutionTests|UIAutomationServiceVisualizerTests" --no-parallel
swift test --package-path Apps/CLI -Xswiftc -DPEEKABOO_SKIP_AUTOMATION --filter "CommanderBinderCommandBindingTests|CommanderBinderTests" --no-parallel
pnpm run lint:docs
git diff --check
```

## Live GUI Evidence

Artifact root: `.artifacts/ui-input-action-first/20260508-014638`.

- Click: `action-click.json` proves action-first `AXPress` on `Single Click`; `click.log` records
  `Single click on 'Single Click' button`.
- Direct set: `action-set-value-live.json` returned success; `see-text-after-setvalue.json` verifies
  `basic-text-field` became `action value 20260508 live`.
- Hotkey: initial runs fell back as `menuShortcutUnavailable`; root cause was bad `AXMenuItemCmdModifiers` decoding.
  After the fix, `menu-list-playground-fixed.json` reports `⌘1` and `⌘⌃1/2` correctly, and the menu action fired.
- Scroll fallback: targeted Playground `vertical-scroll` succeeds under `actionFirst` by falling back to synthesis when
  the action surface is unsupported; `scroll-fixed.log` confirms the fixture offset changed.
- Visualizer anchor: `UIAutomationServiceVisualizerTests` pins that an action result anchor is preferred over the
  coordinate fallback when rendering click feedback.
- Agent turn boundary: streaming and non-streaming agent execution now annotate the first action after a perceive tool
  with `turn_boundary.stop_after_current_step`; the shared loop stops further tool calls in that step and returns before
  requesting another model step.

## Remaining Work

No blocking refactor work remains.

Deferred follow-up:

1. Revisit type/hotkey defaults only for specific apps or menu-bound workflows; keep broad defaults conservative.
2. Add per-app overrides from explicit bug reports and targeted repros, not background metric collection.
