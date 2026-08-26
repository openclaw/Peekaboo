---
summary: 'Source-blind exact-window keyboard behavior contract'
read_when:
  - 'changing background type, paste, press, or keyboard target receipts'
  - 'validating exact-window keyboard behavior without source access'
---

# Exact-window background keyboard behavior contract

## User-visible goal

Peekaboo must deliver type, press, and paste to one exact background window without activating it, and must refuse before dispatch whenever that destination or its focused element is ambiguous, stale, or changed.

## Target

- Type: CLI and MCP tools
- Access: a freshly built `peekaboo` plus mocked CLI/MCP fixtures
- Allowed fixtures: two same-process windows, exact-window snapshots, focused-element receipts, and mock clipboard services only

## User tasks

1. Type or paste text into one exact window while another window from the same process exists.
2. Send a raw chord with an exact window/snapshot receipt and no foreground flag.
3. Attempt app/PID-only typing when multiple eligible windows exist.
4. Attempt exact-window keyboard delivery after focused-element, window-owner, generation, or bounds drift.
5. Use explicit foreground input and legacy process-only input where their established contracts still apply.

## Expected observable behavior

- Exact background success reports background delivery plus target PID and window ID, without application activation or global input.
- Exact routes preserve the focused-element receipt through dispatch.
- Focus evidence comes from one explicit `AXFocused=true` element in a fresh exact-window observation. Cached AX
  trees, application menu elements, and inferred editable controls are not focus receipts.
- Dispatch re-resolves the same focused element under the exact window and revalidates its own focus state before
  every unit; application-level `AXFocusedUIElement` is not sufficient for inactive-window proof.
- Multiple eligible same-process windows without an exact receipt fail before dispatch and request a window selector or fresh snapshot.
- Process-only/app-only/targetless raw press remains a retry-safe, not-dispatched refusal.
- Stale, incomplete, or contradictory receipts fail before any keyboard or clipboard mutation.
- Plain-text paste does not read, write, clear, save, or restore the clipboard.
- Clipboard-backed paste tests use only mocks; no validator step reads or mutates the ambient clipboard.
- Event-only exact Bridge routing retains its existing compatibility surface. Process, exact-window, and pixel-focus typing that may use AXValue delivery requires protocol 1.36 `compositeTypeDelivery`; older or capability-missing sessions refuse before dispatch.
- Direct AX text, editable special keys, and clear report Accessibility-value dispatches with zero key presses. Mixed AX/event typing reports composite delivery, while keyboard fallback reports only its real key events.

## Anti-cheat probes

- Change only the focused window ID and verify the exact request changes from success to no-dispatch refusal.
- Add a same-process sibling window and verify app-only type changes from exact success to ambiguity refusal.
- Remove the exact receipt and verify raw background press refuses rather than silently using process or foreground delivery.
- Change owner generation/bounds and verify no exact keyboard call is recorded.

## Evidence required

- Structured CLI/MCP responses and recorded mock calls.
- Focused unit/integration test output for the canonical target planner and all three keyboard tools.
- Release build and native-only source scan.

## Out of scope

- Reading or mutating the user's ambient clipboard.
- Claiming that macOS acknowledges the semantic effect of a raw chord or Cmd+V.
- Broadening targetless/global input or automatically foregrounding an application.
