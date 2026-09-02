## [4.3.0] - 2026-09-01

### Highlights

- **Credentials and provider authentication are safer.** Secure prompts, stdin, and owner-only files keep secrets out of process lists, while Gemini, OAuth, clipboard, and editor workflows receive additional hardening.
- **Window inspection explains which observation route actually works.** Per-window eligibility distinguishes combined Accessibility capture, pixels-only recovery, and unknown evidence, with safe application-level partial tree context.
- **Background automation is more capable and predictable.** Verified non-modal SwiftUI actions, exact-target inventory isolation, and policy-filtered Agent and MCP catalogs avoid unrelated or foreground-only interference.
- **CLI and MCP workflows start faster and recover more clearly.** Deferred Agent startup, Bridge-bound capture, and precise browser, help, locked-session, and window-close guidance keep routine automation moving.

### Added
- Let trusted MCP hosts explicitly authorize foreground UI for one server process while keeping background-only as the default. Thanks @Austin1serb for #612.
- Report per-window `combined_eligible`, `pixels_only`, or `unknown` observation eligibility in CLI and MCP, including screenshot-only recovery.
- Add an embedding-only Bridge protocol 1.32 API for signed, process-generation-bound observation.
- Add atomic exact-window pixel-focus typing to CLI, MCP, Agent, and Bridge, keeping the focus-only Accessibility write and every background keyboard unit under one target receipt and retry-safe prefix accounting.
- Add explicit foreground modifier-click with exact target preflight and compare-and-swap cursor and focus restoration, preserving newer user or application state instead of overwriting it.

### Changed
- Require explicit checkout-local Swift workspace setup for direct source development, preserving live Commander source in standard gitfile-based submodules without conflicting dependency locations; build, release, and CI helpers own setup automatically.
- Share checked Accessibility timeout ownership with AXorcist across dialog, focus, and window-identity probes, rejecting overlapping scopes while retaining unchecked detached-worker scopes.
- Defer authenticated historical-daemon RPCs until a fallback is actually needed instead of serially probing every stale socket before ordinary CLI commands.
- Read `config credential set` secrets from no-echo prompts, stdin, or owner-only files; let `config provider add` also accept non-secret references; retain deprecated argv compatibility.
- Skip provider discovery and Agent construction for caller-local commands that cannot invoke the Agent.
- Avoid reopening and hashing Bridge screenshot artifacts twice before CLI or MCP consumption while retaining signed client verification and use-time publication checks.
- Skip the ScreenCaptureKit post-capture settlement delay for classic captures that never enter ScreenCaptureKit.
- Reuse validated classic PNG bytes when capture performs no transform instead of encoding the same image twice.

### Fixed
- Bound application inventory from initial PID discovery through final generation validation, keep setup and validation reads off MainActor without queuing blocked native work, and reuse bound click metadata for result labels and diagnostics without post-action application or snapshot lookup.
- Keep daemon health responsive while browser discovery is blocked, report cached browser diagnostics as unconfirmed, and preserve daemon transport failures instead of reporting successful absence or cleanup.
- Reject late element-detection results and expired queued AX work against one absolute deadline, even when timeout delivery is delayed.
- Consume AXorcist 0.1.9 in internal automation and public SwiftPM packages, preserving versioned Commander dependencies with custom scratch paths and nonjoining timeout cancellation.
- Avoid main-thread LaunchServices stalls during global application lifecycle tracking, preserving process-instance identity, launch readiness, and stop/restart safety.
- Distinguish browser handoff parent and receipt metadata refusals from inspection failures, and document the unchanged zero-ACL/xattr requirements, including OS provenance, without fallback.
- Keep client, host, and certification Bridge socket waits off Swift's cooperative executor so concurrent requests can progress without changing deadlines, cancellation, or receipt validation.
- Preserve authenticated Bridge element-action refusals and partial failure details instead of treating their valid error receipts as indeterminate transport failures.
- Recognize the canonical signed OpenClaw Bridge socket for modern receipt-backed protocol negotiation while preserving signer validation and custom-socket protocol 1.28 compatibility.
- Bound debug CLI build-staleness config discovery to the starting directory's ancestors so missing or inaccessible Git metadata cannot cause an endless startup traversal.
- Share the owner-only credential file between app and CLI, trim surrounding whitespace in app edits and legacy imports, ignore unchanged Settings bindings, recover legacy app keys only on explicit import, and keep failed edits visibly unsaved without Keychain prompts. Thanks @vincentkoc for #651.
- Hide and pre-dispatch refuse every pinned browser-provider route that can grant browser user activation under default background authority, while explicit foreground calls report truthful foreground browser-protocol outcomes.
- Preserve exact-window foreground focus evidence under the native mutation lane for signed Bridge receipts, and refuse blind retries after accepted focus loses proof.
- Keep `peekaboo learn` on its injected main-actor service provider instead of crashing when no process-wide tool registry default exists.
- Keep default browser calls existing-receipt-only while restoring explicit-foreground standalone CLI root auto-connect; resolve filtered MCP and Agent catalogs before browser bootstrap while still consuming explicit signed handoffs; and give MCP, Bridge, and Agent sessions generation-safe scoped children whose confirmed cleanup or retained debt prevents shared-root fallback and unsafe reuse.
- Let explicitly browser-only MCP servers start without unrelated ScreenCaptureKit ownership preflight, while keeping unknown and capture-capable catalogs fail closed; reject receiptless isolated Chrome children before authenticated capability-session dispatch and direct headless callers to an exact loopback endpoint.
- Keep `capture action` sampling active across pre-roll, child execution, and post-roll, release only generation-attributed children after terminal-event admission, refuse pre-existing video outputs before child release, reserve startup and descendant-drain time inside the capture deadline, derive post-roll from the recorded child-completion boundary, clear inherited termination-signal masks, keep timeout escalation and cancellable validation off the cooperative/main executors, terminate surviving process-group descendants before validation, reject replaced artifacts, compose focus and child receipts without inventing partial effects, and require Apple-anchored source-stamped host provenance.
- Warm ScreenCaptureKit ownership validation off the main actor before Bridge socket/capability publication, with explicit publication and daemon-readiness reserves beyond the bounded scan.
- Claim and generation-check the host's ScreenCaptureKit lease before trying the concurrent engine first for background Bridge full-screen automatic capture, preserving legacy fallback after modern failure and automatic fallback on every claim failure or competing owner.
- Prevent agent-spawned exec children from retaining the global ScreenCaptureKit transaction lock after an interrupted capture owner exits.
- Return exit status 2 when `verify` cannot evaluate state because its underlying tool fails.
- Report background text, editable special keys, and clears with their actual AXValue, event, or composite delivery; count only real key events as key presses; preserve the planned receiver literal after escape processing; and require protocol 1.36 before AX-capable remote type requests.
- Revalidate exact-window focused elements and the application's internal key window before typing, reject parent targets with attached sheets while preserving independently identified exact sheet targets, confirm clear-plus-literal text only from a generation-bound value change after bounded event settlement, keep pixel-focus setup confirmation separate from its typing leaf, and stop reporting no-change, missing, or dispatched-but-unverified outcomes as typed characters.
- Require process-generation receipts for process-scoped `action` and `set-value` snapshots, revalidate them before dispatch, and preserve their canonical target metadata through MCP and signed Bridge results.
- Bind `action` and `set-value` snapshots, resolved AX elements, outcomes, and signed Bridge 1.37 results to one process generation; suppress their Bridge operations for unsupported providers, reject downgraded or receiptless sessions before provider dispatch, and refuse PID reuse, foreign elements, or targetless success before retry.
- Require explicit standalone CLI foreground consent for application focus/switch and Dock visibility changes, and reject contradictory app-switch selectors before runtime discovery.
- Scope persistent MCP and Agent browser refs to one caller, provider child epoch, page, snapshot, and document generation; require the pinned provider's structured capability data, reserve exact targets before permission-bearing setup, preserve post-dispatch failure evidence while withholding invalid refs, and let independent background session lanes overlap under origin-recoverable durable cross-process invalidation while same-target access and Bridge providers without authenticated scoped-session support remain fail closed; explicit signed handoffs transfer one exact connection into a current Bridge host's isolated opaque-reference session.
- Bind Bridge 1.34 Chrome channel connections to an exact live Chrome bundle, native process-owned DevTools listener, and approval-gated WebSocket under one 90-second deadline, verifying `Browser.getVersion` once without legacy HTTP discovery or repeated permission probes and failing closed on helper-service names, file, socket, generation, or endpoint drift.
- Authenticate native Chrome channels against Google Team ID `EQHXZ8M8AV`, pin the exact signed identifier and CDHash for the process generation, and enumerate the target process's complete listener inventory independently of Peekaboo's file-descriptor limit.
- Honor the configured default save directory for pathless pixel-only `see` captures and add collision-resistant generated filenames for concurrent callers, while preserving explicit paths and stdout streaming. Thanks @PollyBot13 for #607.
- Preserve the exact browser target-lock refusal so reconnecting to a different live Chrome channel or endpoint tells callers to disconnect first instead of reporting a generic unavailable target.
- Advertise only actions and input shapes reachable under immutable background-only authority, require background paste window selectors to include one app or PID owner, and keep foreground-capable app, Dock, Space, dialog, menu, browser, clipboard, and paste workflows explicit.
- Emit one lossless target identity and process-generation receipt across CLI envelopes and App MCP responses, preventing extra metadata from overriding the canonical target.
- Prefer a sole live child sheet or alert beneath its exact structural parent window, preserve multi-child ambiguity, and keep parent-window recovery guidance intact across remote dialog reads.
- Bind snapshots to cryptographically random `ps1_` references owned by their creating local or Bridge host, route concrete references to one authenticated producer before normal host preference, and refuse malformed, stale, duplicated, incapable, or explicitly misrouted hosts before publication or input.
- Keep Bridge 1.34 snapshot ownership and Accessibility-value click policy independently capability-gated, preserve omitted-policy behavior for old clients, enforce explicit opt-outs before dispatch, and retain cleanup-only removal of legacy timestamp snapshot directories without making their IDs actionable.
- Pin background scrolls to negotiated protocol 1.35 exact-window receipts so legacy hosts refuse before dispatch and retry-unsafe failures retain their exact target.
- Resolve repeated stable window inventory rows consistently across CLI and MCP instead of falsely reporting ambiguity.
- Downscale straight-alpha legacy screenshots to logical 1x instead of silently returning Retina-sized pixels.
- Bound exclusive ScreenCaptureKit transaction-lock waits inside the Bridge request envelope so a wedged peer fails clearly instead of hanging capture indefinitely. Thanks @SebTardif for #599.
- Send Gemini API keys in request headers, require HTTPS OAuth endpoints, and redact OAuth state. Thanks Vincent Koc for #575 and Tachikoma #73.
- Enforce a 10 MiB clipboard and paste file payload limit on the opened descriptor to prevent file-replacement races. Thanks @SebTardif for #561.
- Prevent configured editors from injecting command-line options. Thanks @SebTardif for #562.
- Keep Agent traces privacy-safe and deterministic, and mark unknown mutation dispatch as unsafe to retry.
- Hide foreground-only pointer tools and unsupported input shapes from background Agent and MCP catalogs while preserving explicit CLI foreground consent.
- Reject foreground delivery reported by background CLI paste and preserve canonical target receipts for missing or conflicting results.
- Fall back to native app hiding when Accessibility proves `AXHide` was rejected before dispatch.
- Keep verified non-modal SwiftUI actions available, isolate exact targets from unrelated incomplete inventory, and recognize fresh `inspect_ui` observations.
- Preserve process-scoped Accessibility receipts and return read-only `application_partial` trees without reusable snapshots or mutation authority.
- Bind persistent MCP capture to its selected Bridge, keep classic capture request-local, and preserve precise signed refusals, causes, and recovery hints.
- Bind `set-value` results to the exact requested element and refuse incompatible Bridge hosts before dispatch.
- Treat confirmed window disappearance after `window close` as success.
- Fail MCP `see` when element detection did not run while accepting genuine empty scans. Thanks @SebTardif for #563.
- Require HTTP 200 responses when testing provider connectivity. Thanks @SebTardif for #560.
- Explain why locked macOS sessions cannot be captured even when `screen list` still reports connected displays.
- Restore terminal echo when credential prompts receive signals and reject background prompts or insecure credential files.
- Deduplicate runtime flags and improve unknown-command, browser reconnect, help, `learn`, schema, and background-automation guidance.
- Validate contradictory window and Space selectors before runtime-host discovery so malformed requests cannot start support services or mask the actionable error.
- Explain that exact transient sheets may require read-only owning-process Accessibility inspection before screenshot/OCR fallback, without granting partial app trees mutation authority.
- Bound retained native application metadata to eight operations per host process through timeout/cancellation and autorelease cleanup, shed overload as partial rows, and keep exact-target AX reads independent.
- Include nested dialog static text and nonblank AX text metadata fallbacks in `dialog list`, preserving dialog scope and control order.
- Accept canonical v2 prebuilt Playground fixtures in native validation with strict source, lock, toolchain, bundle, and Foundation signature checks, retaining v1 only for the current invocation's local build.
