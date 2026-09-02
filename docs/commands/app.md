---
summary: 'Control macOS apps via peekaboo app'
read_when:
  - 'launching/quitting/focusing apps as part of an automation flow'
  - 'auditing running apps or force cycling foreground focus'
---

# `peekaboo app`

`app` bundles every app-management primitive Peekaboo exposes: launching, quitting, hiding, relaunching, switching/focusing, and listing processes. Commands run through the selected Peekaboo runtime host so they share its macOS session, LaunchServices, and AX view instead of the caller's sandbox.

## Subcommands
| Name | Purpose | Key flags |
| --- | --- | --- |
| `launch` | Verify an exact running app in the background, or explicitly start/open it in the foreground. | `--bundle-id`, `--open <path|url>` (repeatable), `--new-instance`, `--wait-ready`, `--wait-for-window`, `--foreground`. |
| `quit` | Quit one app or *all* regular apps (with optional exclusions). | Positional `<app>` or `--app`, `--pid`, `--expected-process-start-identity`, `--all`, `--except "Finder,Terminal"`, `--force`. |
| `relaunch` | Quit + relaunch the same app with explicit foreground consent. | Positional `<app>` or `--app`, or `--pid`; `--wait`, `--force`, `--wait-until-ready`, `--foreground` (required). |
| `hide` / `unhide` | Hide an app, or unhide and activate it with explicit consent. | Positional `<app>` or `--app`, or `--pid`; unhide requires `--activate`. |
| `switch` | Activate a specific app or cycle Cmd+Tab style with explicit foreground consent. | Exactly one positional `<app>`/`--to` or `--cycle`; `--verify` only with an app target; `--foreground` required. |
| `focus` | Activate and focus an app through the same service path as the MCP app tool. | Positional `<app>` or `--app`, or `--pid`; `--foreground` required. |
| `list` | App-management view of running apps, filtering hidden/background apps by default. | `--include-hidden`, `--include-background`. |

## Implementation notes
- App mutations accept only an exact case-insensitive application name, exact bundle ID, or explicit `PID:<n>`/`--pid`. Partial-name matching remains available to read-only discovery, but a mutation such as `--app Saf` is refused before any lifecycle action is dispatched.
- Prohibited helpers remain exact-name/bundle candidates whenever their process generation is readable. Only repeatedly confirmed foreign-effective-UID, prohibited rows whose full generation reads fail with `EPERM` are excluded from native mutation inventory without an omission warning. All uncertain omissions still prevent name/bundle uniqueness; read-only listing and explicit-PID lifecycle targeting are unchanged. See [mutation inventory completeness](../application-resolving.md#mutation-inventory-completeness).
- Launch resolves explicit paths, bundle IDs, PID selectors, and friendly names on the selected runtime host. Without `--foreground`, it may only return an exact already-running app as a verified no-op; it may resolve the application URL but never dispatches a LaunchServices open/start. Cold launch, `--open`, `--new-instance`, and relaunch refuse before dispatch because macOS does not provide a trustworthy nonactivation guarantee. These refusals report `INTERACTION_FAILED`, `effect: refused`, `retry_safe: true`, and `mutation_dispatched: false`, with explicit foreground guidance. Background launch also requires a host that advertises this exact no-op contract, so a rolling upgrade cannot delegate to an older host that would cold-launch. The deprecated `--no-focus` flag remains a no-op compatibility alias.
- Background no-op `launch --wait-ready` and `--wait-for-window` retain the selected PID/process-generation receipt throughout their read-only waits. A readiness failure remains explicitly retry-safe with `mutation_dispatched: false`. A `PID:` selector stays pinned to that exact process generation for both the no-op and a plain foreground activation; it cannot be combined with `--open` or `--new-instance`. Foreground launch keeps the full existing LaunchServices behavior for path/name/bundle selectors: it can start windowless/accessory apps, deliver documents/URLs, create a distinct process, and wait up to 10 seconds for a real WindowServer window. `relaunch` retains its single `--wait-until-ready` spelling and requires `--foreground` before the target is resolved or quit.
- JSON launch output returns the launch-bound numeric compatibility field `process_start_identity` plus the lossless authoritative string `process_start_identity_decimal` beside `pid`, along with refreshed `window_count`, `window_ready`, and `window_ids`. Relaunch uses `new_process_start_identity` and authoritative `new_process_start_identity_decimal`. JSON-number consumers must not use the numeric forms for exact comparison because values above 2^53 can lose precision. A current native host captures that process generation from the exact process selected by LaunchServices and refuses the result if the PID is recycled before return. Older runtime hosts may omit the process identity for foreground launch, but background launch fails closed unless the host advertises the safe no-op contract; cleanup callers must never probe a returned PID to manufacture a new receipt. `window_identity` is `exact` when the window IDs came from WindowServer and `unknown` for an older runtime host that cannot provide that metadata.
- MCP app lifecycle and focus results expose the same generation through `target_identity.kind: process` and `target_identity.process_start_identity_decimal`. Agents must chain that target identity; the generic numeric `process_start_identity` metadata is compatibility-only and is intentionally not exported as authoritative safety metadata.
- Quit mode supports `--all` plus `--except`, automatically ignoring core system processes (`Finder`, `Dock`, `SystemUIServer`, `WindowServer`). Bulk quit targets only generation-pinned applications whose bounded metadata explicitly classifies them as regular; accessory, prohibited, and incomplete rows are never treated as regular by default. Controlled cleanup can pair `--pid` with the lossless unsigned-decimal `--expected-process-start-identity` (including the full UInt64 range); Peekaboo atomically rejects a recycled PID instead of terminating its replacement. Each JSON result publishes the frozen target plan as `pid` plus authoritative `process_start_identity_decimal`. When quits fail, the command prints hints about unsaved changes and suggests `--force`.
- Hide remains background-capable. Unhide requires `--activate` before runtime-host resolution and carries the selected PID/process-generation receipt through verified activation because showing an application's windows can move them in front. Hosts that cannot enforce the receipt are rejected, and the legacy identifier-only Bridge unhide operation is refused.
- `switch --cycle` synthesizes Cmd+Tab events using `CGEvent` so it behaves like the real keyboard shortcut; `switch --to` activates the exact PID resolved via AX. Both switch forms and `app focus` require `--foreground` before application lookup or global input dispatch. Switch accepts exactly one app target or `--cycle`; it never ignores a target in favor of a global cycle.
- App activation is successful only after the exact resolved PID reports active and Workspace-frontmost. When the
  target owns visible ordinary windows, the frontmost WindowServer window must also belong to that PID. Peekaboo
  first uses native application activation, then falls back to the application's AX frontmost attribute when macOS
  accepts the request without completing it. Multi-window apps activate all of their windows; use `window focus`
  when one specific window must become key.
- CLI and MCP focus/switch/unhide operations never reduce a selected application to a bare PID or name before activation; the runtime host rechecks the original process-generation receipt immediately before and after native activation.
- `switch --verify` performs an additional command-level confirmation after the shared verified activation path (not
  supported with `--cycle`).
- Supply one selector shape. Launch rejects a positional app combined with `--bundle-id`; app lifecycle commands reject a textual `--app` combined with `--pid`. A redundant `--app PID:123 --pid 123` pair is accepted only when both PIDs match.
- With `--foreground`, `relaunch` sends the initially selected PID/process-generation receipt, quit, termination polling (up to 5 s), the requested delay, and launch as one daemon-held transaction, so even a short daemon idle timeout cannot strand the app closed. The host rejects PID reuse before quit, refuses to relaunch its own daemon, launches via bundle ID or bundle path, can wait for `isFinishedLaunching`, and returns authoritative `previous_process_start_identity_decimal` and `new_process_start_identity_decimal` generations for race-free follow-up cleanup.
- `app list` filters hidden/background apps unless `--include-hidden` or `--include-background` is passed and emits its established `data.apps` payload. Its one-second absolute overall deadline starts before PID discovery and covers frontmost lookup, the WindowServer snapshot, LaunchServices metadata, final process-generation validation, and result publication. Seed discovery, catalog reads, and final validation run off MainActor on one process-wide native inventory slot; a blocked getter retains that slot until it returns, and repeated inventory requests fail without queuing more work on it. Mutation inventory follows the same deadline and native-slot rules, including selector metadata reads. Failed, busy, or expired inventory is an error, never a complete empty desktop or proof that an app is absent.
- Per-app enrichment schedules up to eight concurrent async waits per inventory request, each with a 250 ms caller budget limited by the remaining overall deadline. Detached LaunchServices metadata has a separate process-wide limit of eight retained operations shared by all application services, PIDs, and process generations. Admission reserves capacity through native return/throw and autorelease cleanup, even after the caller times out or cancels. There is no waiting backlog or result coalescing: duplicate `(PID, process generation)` requests and requests beyond capacity are rejected immediately. Dispatched wrappers that expire before starting retain their reservation until they drain without invoking the getter. Permanently blocked getters permanently consume capacity. This limit covers detached application metadata per host process, not all AX work, threads, or the machine. Exact-target AX window, focus, and typing readback use independent lanes, including for the same PID and generation. Cancellation and overall expiry return without waiting for blocked native getters; late results are discarded.
- Within the overall budget, an overloaded or timed-out inventory row retains its stable PID/generation/window IDs, carries `metadata_warnings`, and omits `is_hidden` rather than guessing; use both inclusive flags to retain rows whose hidden state and activation policy are unknown. Partial rows are returned only when seed discovery, final generation validation, and publication all complete within that budget. Overall timeout or failed final validation returns an inventory error, never partial or empty success. Changed generations are still omitted, cancellation still propagates, and incomplete rows remain ineligible for bulk quit. Top-level `warnings` makes a partial result visible in JSON and text output; row warnings also survive Bridge transport. Each current native process generation is available as `process_start_identity` plus the lossless canonical string `process_start_identity_decimal`; shell/JSON-number consumers must use the decimal string for exact comparison and treat missing values from older hosts as unknown. The result's `schema_capabilities` array advertises `processStartIdentityDecimal` even when `apps` is empty, so installers can require the lossless receipt contract without inferring CLI capability from ambient processes.

## Examples
```bash
# Verify an already-running Xcode generation without dispatching a launch
peekaboo app launch "Xcode" --wait-ready

# Open a project with explicit foreground consent
peekaboo app launch "Xcode" --open ~/Projects/Peekaboo.xcodeproj --foreground

# Start an independent TextEdit process with explicit foreground consent
peekaboo app launch "TextEdit" --new-instance --wait-for-window --foreground

# Explicitly activate Safari after launching it
peekaboo app launch "Safari" --foreground

# Unhide and activate one exact app
peekaboo app unhide TextEdit --activate

# Quit everything but Finder and Terminal
peekaboo app quit --all --except "Finder,Terminal"

# Quit one app positionally
peekaboo app quit TextEdit

# Atomically quit only the saved process generation
peekaboo app quit --pid 1234 --expected-process-start-identity 987654321 --force

# Cycle to the next app exactly once
peekaboo app switch --cycle --foreground

# Switch and verify the app is frontmost
peekaboo app switch Safari --verify --foreground

# Focus an app without a separate launch
peekaboo app focus Safari --foreground
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target with `peekaboo app list`, `peekaboo window list`, or `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
