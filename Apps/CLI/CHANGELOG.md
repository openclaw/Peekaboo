# Changelog

All notable changes to Peekaboo CLI will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Highlights

- **Credentials and provider authentication are safer.** Secure prompts, stdin, and owner-only files keep secrets out of process lists, with additional Gemini, OAuth, clipboard, and editor hardening.
- **Window inspection explains the available observation route.** Per-window results distinguish combined Accessibility capture, screenshot-only recovery, and evidence that needs refreshing.
- **Background automation is more capable and predictable.** Verified non-modal SwiftUI actions, exact-target isolation, and policy-filtered Agent and MCP tools avoid unsafe foreground interference.
- **Everyday commands start faster and recover more clearly.** Deferred Agent startup, Bridge-bound capture, and actionable browser, help, locked-session, and window-close guidance reduce surprises.

### Added
- Report per-window `combined_eligible`, `pixels_only`, or `unknown` observation eligibility, including screenshot-only recovery.
- Add `type --at` for atomic exact-window background focus-only Accessibility input plus typing from one fresh screenshot snapshot.
- Add `click --modifiers ... --foreground` with exact snapshot preflight and truthful cursor/focus restoration reporting.

### Changed
- Read `config credential set` secrets from no-echo prompts, stdin, or owner-only files; let `config provider add` also accept non-secret references; retain deprecated argv compatibility.
- Skip provider discovery and Agent construction for caller-local commands that cannot invoke the Agent.
- Avoid reopening and hashing Bridge screenshot artifacts twice before CLI or MCP consumption while retaining signed client verification and use-time publication checks.
- Skip the ScreenCaptureKit post-capture settlement delay for classic captures that never enter ScreenCaptureKit.
- Reuse validated classic PNG bytes when capture performs no transform instead of encoding the same image twice.

### Fixed
- Keep `capture action` sampling active across pre-roll, child execution, and post-roll, release only generation-attributed children after terminal-event admission, refuse pre-existing video outputs before child release, reserve startup and descendant-drain time inside the capture deadline, derive post-roll from the recorded child-completion boundary, clear inherited termination-signal masks, keep timeout escalation and cancellable validation off the cooperative/main executors, terminate surviving process-group descendants before validation, reject replaced artifacts, compose focus and child receipts without inventing partial effects, and require Apple-anchored source-stamped host provenance.
- Report background text, editable special keys, and clears with their actual AXValue, event, or composite delivery; count only real key events as key presses; preserve the planned receiver literal after escape processing; and require protocol 1.36 before AX-capable remote type requests.
- Revalidate exact-window focused elements and the application's internal key window before typing, reject parent targets with attached sheets while preserving independently identified exact sheet targets, confirm clear-plus-literal text only from a generation-bound value change after bounded event settlement, keep pixel-focus setup confirmation separate from its typing leaf, and stop reporting no-change, missing, or dispatched-but-unverified outcomes as typed characters.
- Require explicit standalone CLI foreground consent for application focus/switch and Dock visibility changes, and reject contradictory app-switch selectors before runtime discovery.
- Bind Bridge 1.34 Chrome channel connections to an exact live Chrome bundle, native process-owned DevTools listener, and approval-gated WebSocket under one 90-second deadline, verifying `Browser.getVersion` once without legacy HTTP discovery or repeated permission probes and failing closed on helper-service names, file, socket, generation, or endpoint drift.
- Authenticate native Chrome channels against Google Team ID `EQHXZ8M8AV`, pin the exact signed identifier and CDHash for the process generation, and enumerate the target process's complete listener inventory independently of Peekaboo's file-descriptor limit.
- Honor the configured default save directory for pathless pixel-only `see` captures and add collision-resistant generated filenames for concurrent callers, while preserving explicit paths and stdout streaming. Thanks @PollyBot13 for #607.
- Preserve the exact browser target-lock refusal so reconnecting to a different live Chrome channel or endpoint tells callers to disconnect first instead of reporting a generic unavailable target.
- Advertise only actions and input shapes reachable under immutable background-only authority, require background paste window selectors to include one app or PID owner, and keep foreground-capable app, Dock, Space, dialog, menu, browser, clipboard, and paste workflows explicit.
- Emit one lossless target identity and process-generation receipt across CLI envelopes and App MCP responses, preventing extra metadata from overriding the canonical target.
- Let exact `dialog` targeting prefer one active child sheet or alert beneath its structural parent, retain ambiguity for multiple children, and preserve actionable parent-window recovery hints through Bridge routing.
- Bind snapshots to strict producer-owned `ps1_` references, route concrete IDs to their unique authenticated local or Bridge host before normal preference, and fail closed on malformed, stale, duplicate, incapable, or explicitly misrouted hosts while keeping legacy timestamp directories cleanup-only.
- Pin background scrolls to negotiated protocol 1.35 exact-window receipts so legacy hosts refuse before dispatch and retry-unsafe failures retain their exact target.
- Downscale straight-alpha legacy screenshots to logical 1x instead of silently returning Retina-sized pixels.
- Bound modern capture transaction-lock waits inside the Bridge request envelope so a wedged peer fails clearly instead of hanging indefinitely. Thanks @SebTardif for #599.
- Send Gemini API keys in request headers, require HTTPS OAuth endpoints, and redact OAuth state. Thanks Vincent Koc for #575 and Tachikoma #73.
- Enforce a race-safe 10 MiB limit for clipboard and paste file payloads. Thanks @SebTardif for #561.
- Prevent configured editors from injecting command-line options. Thanks @SebTardif for #562.
- Keep Agent traces privacy-safe and deterministic, and mark unknown mutation dispatch as unsafe to retry.
- Hide foreground-only pointer tools and unsupported input shapes from background Agent and MCP catalogs while preserving explicit CLI foreground consent.
- Keep verified non-modal SwiftUI actions available, isolate exact targets from unrelated incomplete inventory, and recognize fresh `inspect_ui` observations.
- Preserve process-scoped Accessibility evidence and expose safe read-only application-level tree context without mutation authority.
- Bind MCP capture to its selected Bridge, keep classic capture request-local, and preserve precise refusal and recovery messages.
- Bind `set-value` results to the exact requested element and refuse incompatible Bridge hosts before dispatch.
- Treat confirmed window disappearance after `window close` as success.
- Fail MCP `see` when element detection did not run while accepting genuine empty scans. Thanks @SebTardif for #563.
- Require HTTP 200 responses when testing provider connectivity. Thanks @SebTardif for #560.
- Explain why locked macOS sessions cannot be captured even when `screen list` still reports connected displays.
- Restore terminal echo when credential prompts receive signals and reject background prompts or insecure credential files.
- Deduplicate runtime flags and improve unknown-command, browser reconnect, help, `learn`, schema, and background-automation guidance.

## [4.2.2] - 2026-08-20

### Highlights

- **Background automation does more without stealing focus.** Exact-window middle and triple clicks join keyboard, menu, window, and app actions that refuse ambiguous targets.
- **Previously invisible controls and windows are usable again.** Editable TextEdit fields and exact minimized or off-Space windows remain discoverable.
- **Agent authority is explicit before anything runs.** Dry-run text and JSON explain requested and effective foreground access without touching models, tools, or sessions.
- **Long-running CLI workflows stay responsive.** Bounded AX observers, command deadlines, and VibeTunnel helpers join safer retries, reused Bridge handshakes, reliable SSH input, and provisioning-free companion deployment.

### Added
- Add exact-window background middle and triple clicks without activating the target or moving the cursor.
- Show requested and effective foreground authority in `agent --dry-run` text and JSON without invoking models, tools, or sessions.
- Add authenticated `peekaboo bridge receipt validate` with the live host's source commit and negotiated protocol metadata.
- Add Bridge protocol 1.30 application and window inventories that distinguish complete from partial evidence while retaining conservative compatibility with older hosts.

### Fixed
- Pin background type, paste, press, targeted clicks, and app, window, or menu mutations to one exact process and window generation; refuse fuzzy, ambiguous, stale, or incomplete targets before dispatch.
- Keep TextEdit document fields and other editable controls discoverable when optional Accessibility attributes are unavailable.
- Resolve exact minimized and off-Space windows without treating unreadable WindowServer catalogs as proof that a target is absent.
- Preserve exact signed read-only selectors across application names, PIDs, bundle or executable paths, and window IDs or titles; reject contradictory evidence.
- Report application and window inventory completeness honestly while keeping complete AX-only listings usable without Screen Recording.
- Pin foreground menu listing and clicks to the exact process and window, preserving truthful focus outcomes.
- Prevent duplicate scrolling and SwiftUI tab presses after accepted input; preserve exact dispatch counts and require fresh observation before retrying.
- Return target-attributed, retry-unsafe outcomes when an accepted Accessibility `set-value` write cannot be verified.
- Clean up cancelled held shortcuts only against their original process generation.
- Return structured connection and discovery errors instead of crashing on malformed persisted custom-provider URLs. Thanks @SebTardif for #488.
- Bound wedged VibeTunnel terminal-title helpers and fall back to ANSI title updates. Thanks @SebTardif for #489.
- Explain actionable `set-value`/`set_value` recovery for unfocused background windows.
- Align CLI help and Agent guidance around snapshot-pinned background input, targeted dialog entry, and explicit foreground consent.
- Bound AX observer registration and removal, and preserve Realtime completion, cancellation, and timeout outcomes. Thanks @SebTardif for AXorcist #46/#47 and Tachikoma #68.
- Keep CLI wall-clock command deadlines bounded even under sustained executor load.
- Reuse authenticated Bridge handshakes and explain implicit-host rejection before falling back locally.
- Reject empty interaction commands, targetless background typing, malformed browser requests, and invalid video inputs before runtime discovery while explicit help still succeeds.
- Preserve JSON flags after `--` as child-command arguments.
- Preserve Option/Meta chords and fragmented escape sequences across higher-latency SSH connections.
- Build deployment companion apps unsigned, then apply the Foundation signature manually before transactional installation to avoid Xcode provisioning stalls while preserving exact signer and TCC identity.

## [4.2.0] - 2026-08-16

### Highlights

- **Background-first automation is signed and fail closed.** Bridge protocol 1.29 binds peer-authenticated sessions to exact requests, targets, results, process generations, and retry semantics, with replay protection and bounded rollover for long-running automation.
- **More UI automation stays in the background.** Exact browser sessions, dialog click/dismiss/input, coordinate-only snapshots, and opaque WKWebView/Tauri scrolling preserve the foreground app and physical cursor, while Space switching and followed moves require explicit foreground consent.
- **Target and result semantics now have one canonical path.** Shared selector/receipt adapters and application/window outcomes keep CLI, MCP, Bridge, services, and Agent behavior aligned, refusing stale, ambiguous, or incomplete evidence before dispatch.
- **Exact-target automation is substantially faster without weakening identity checks.** Generation-proven PID/window observations measured 141x faster combined resolution, and one-pass Bridge peer identity lookup reduced signed app-inventory median latency by 29.6%.
- **Native-only embedding and release are first-class.** Signed macOS apps can host a lean background Bridge without Core, provider, browser, daemon, or AppleScript dependencies, while branded DMGs use direct Finder metadata outside the signed app and no GUI automation.

### Added
- Add Bridge protocol 1.29 peer-bound signed operation sessions and exact target/result receipts, with bounded rollover, replay protection, and fail-closed recovery for long-running background automation.
- Make protocol 1.29 browser receipts require a fully resolved explicit DevTools endpoint, and make exact dialog text entry use background Accessibility value mutation while refusing receipt-incapable legacy dialog mutations before dispatch.
- Add protocol 1.26 explicit-reference-only snapshot publication so exact-window `see --no-elements` can return coordinate receipts without replacing implicit latest element maps, while older hosts fail before allocation.
- Add `browser connect --browser-url` for an exact loopback DevTools endpoint and expose its pinned browser identity in status metadata through Bridge protocol 1.26.
- Add protocol 1.25 exact dialog click/dismiss receipts with unique target planning, raw AX identity revalidation, verified disappearance outcomes, and read-only targeted listing.
- Add capability-gated exact-window background wheel delivery for opaque WKWebView/Tauri scroll targets, with retry-unsafe unverifiable outcomes and no activation or shared-cursor fallback.

### Fixed
- Complete the Bridge 1.29 receipt-session handshake before daemon status or stop control, validate explicit move snapshots before focus setup, and preserve actionable quit recovery over generic escalation guidance.
- Require explicit foreground consent for Space switching and followed window moves across CLI and MCP, and compose their native move/switch receipts without synthesizing success or dispatch counts.
- Establish and verify a window's destination Space before removing prior memberships, and retain its exact generation-bound identity through Space-aware focus.
- Let later exact maximize readbacks supersede transient poll errors while preserving cancellation and identity contradictions, and route idempotent no-change receipts by the actual execution host.
- Return canonical retry-safe pre-dispatch refusals when window owner-generation or bounds-provenance evidence does not match the selected mutation target.
- Bind protocol 1.29 window and frontmost capture receipts to the exact captured process/window, reject missing or contradictory target metadata, and keep screen/area captures explicitly global.
- Keep root help and version order-independent across canonical kebab- and camel-case runtime-option aliases while preserving correct missing-value errors.
- Treat `capture video` as caller-local media ingestion so valid files and typed media failures bypass Screen Recording and ScreenCaptureKit-owner preflight while live capture remains gated.
- Keep normal exact-window Finder `see` usable when the window exposes no semantic AX value, without weakening hard Accessibility-read failures or the typed incomplete-evidence refusal.
- Project dialog input and forced Escape through canonical unverified outcomes and exact PID/generation/window receipts so retained-value evidence, driver cancellation, legacy Bridge PID targets, and concurrent-controller races cannot be reported as confirmed effects.
- Refuse exact-window combined `see` results when Accessibility returns no usable elements, including legacy Bridge responses that omit the incomplete-read marker, while preserving the requested raster and explicit `--no-elements` screenshot-only success.
- Validate request-only `click`, `move`, `type`, and `drag` arguments before runtime-host selection so malformed requests cannot be masked by Bridge availability or trigger unnecessary host startup.
- Keep concrete interaction snapshots out of ScreenCaptureKit-owner preflight because they cannot refresh or capture, and give omitted/latest snapshot flows an actionable `see --capture-engine classic` recovery.
- Reject unknown and non-object MCP `tools/call` arguments as JSON-RPC invalid params before policy checks or tool dispatch, recursively honoring the closed schemas advertised by `tools/list`.
- Keep browser CLI calls on one current-build reusable daemon, probe Chrome before reporting connected, require explicit reconnect instead of falling back to another same-channel profile after connection loss, and bind browser typing/key presses to an exact uid in one host-owned sequence.
- Fail browser uploads closed through a private per-session Chrome MCP temporary root, race-safe regular-file staging, a 100 MiB bound, and child-before-cleanup cancellation without unrestricted path access.
- Report exact standard windows with live attached sheets as dialog-active observations, using shared native role evidence without changing the parent window receipt.
- Preserve default automatic capture through an owner-aware Bridge by clamping it to classic-only around an auxiliary legacy ScreenCaptureKit owner, while explicit modern and owner-unaware routes remain fail-closed.
- Preserve canonical application/window outcome and retry semantics across CLI, MCP, and Bridge—including failed quits and truthful no-op launch output—while retaining legacy JSON fields and v4.1.0 public APIs.

## [4.1.0] - 2026-08-13

### Highlights

- **Background is the fail-closed default.** CLI interactions revalidate exact process, window, bounds, snapshot, capability, and focused-element receipts, demand explicit consent for foreground or shared-pointer input, and refuse stale, ambiguous, or targetless requests before dispatch.
- **JSON action semantics are canonical.** Bridge outcomes, snapshot mutation leases, and the shared sequence accumulator expose consistent effect, dispatch, retry, evidence, and escalation fields while read-only errors remain free of mutation metadata.
- **Observation gained exact OCR and ROI paths.** `see` can run host-local Vision OCR or exact-window regions while preserving Retina coordinates, snapshot provenance, and background-only routing; AX-only inspection no longer claims a capture backend.
- **Agent runs are safer to resume and overlap.** Sessions are immutable background-only by default, tool providers and UI snapshots are generation/session owned, and typed failures survive persistence, terminal handling, and execution traces.
- **Capture and Bridge startup are faster without hidden fallbacks.** Reusable capture plans, bounded one-shot ScreenCaptureKit capture, event-driven listener wakeups, concurrent diagnostics, and strict explicit-socket routing avoid polling, persistent streams, and silent caller-local work.
- **The CLI and companion runtime are native-only and externally consumable.** AppleScript permission and execution surfaces are gone, release gates reject Apple Events/OSA behavior, and the restored SwiftPM facade exports the lean Foundation, Protocols, AutomationKit, and Bridge products.

### Added
- Add receipt-pinned exact-window background `type`, `paste`, and `press`, with focused-element revalidation and fail-closed app/PID ambiguity handling.
- Add `see --ocr` for additive host-local Vision text with preserved AX warnings, exact snapshot receipts, logical bounds, confidence, background-only observation, and fail-before-dispatch compatibility with older Bridge hosts.
- Add `see --roi x,y,width,height` for stateless exact-window crops with fresh snapshot receipts, ROI-local element output, and safe coordinate metadata.

### Changed
- Default new agent configurations to GPT-5.6 and Claude Opus 5 while keeping credential-only Anthropic discovery on Opus 4.8 for zero-retention compatibility and preserving explicit model selections.
- Encode annotated observations directly from their rendered bitmap, removing redundant PNG/TIFF round trips while preserving exact pixels, metadata, and output paths.
- Reuse two-second, owner-host-local ScreenCaptureKit exact-window screenshot plans without caching pixels, revalidating process generation, window receipt, display topology, and scale around every capture while exposing miss/hit generation diagnostics.
- Wake Bridge hosts on kernel listener readiness instead of polling `accept` every 25 ms, draining queued clients per notification while preserving bounded, descriptor-safe shutdown.
- Make Agent sessions immutable background-only by default, centrally refusing foreground/global input, activation, raw press, shared-pointer, persistent clipboard mutation, shared system UI mutations, Space switch/follow, browser setup/fronting, and Shell-tool access before dispatch while retaining Space listing and unfollowed window placement; `--allow-foreground` sets a new session's immutable maximum, must be explicitly repeated on resume, and never exposes the Shell tool, while session output exposes full copyable IDs, tasks, lifecycle meaning, and stored policy.

### Fixed
- Compose setup, delivery, cleanup, cancellation, and refusal receipts through one Foundation action-sequence owner so foreground focus cannot be erased by a no-dispatch leaf and CLI/MCP target refusals expose complete retry guidance.
- Make explicit Bridge socket overrides fail closed when unavailable instead of reporting a successful local fallback.
- Validate `see` selectors, explicit caller-local PIDs, and `scroll` directions before runtime-host and ScreenCaptureKit ownership preflight so request errors cannot be masked by ambient capture state.
- Consume explicit snapshots for further mutations when a canonical action outcome requires fresh observation or is unavailable, refusing duplicate click/action/set-value/scroll dispatch before it reaches the app while preserving read-only snapshot evidence.
- Report canonical refused, retry-safe, not-dispatched outcomes for pre-dispatch CLI and MCP action validation without attaching desktop semantics to read-only errors or overwriting dispatched receipts.
- Preserve integer-valued Agent tool data across Codable and Foundation JSON conversion instead of mistaking numeric `0` and `1` for booleans.
- Carry verified outcomes for receipt-pinned background window close, minimize, restore, maximize, move, resize, and set-bounds through Bridge protocol 1.23 while older hosts remain conservative.
- Bind each discovered Agent tool to its exact provider and registry generation, recover unchanged bindings after transient discovery failures while refusing ambiguous or stale ownership, and preserve boolean/integer MCP arguments plus descriptions, enums, array item types, and required fields through shared typed conversion paths.
- Isolate MCP and Agent UI snapshot histories by server/session, including latest selection, invalidation, capacity, duplicate IDs, and lifecycle cleanup, so concurrent agents cannot replace or evict each other's targets.
- Validate every registered command signature and default-subcommand target before routing, including positional ordering and semantic-label uniqueness; reject duplicate command, subcommand, option, and flag definitions deterministically instead of trapping or silently selecting one, and keep daemon `--bridge-socket` on the canonical runtime option.
- Preserve `capture action` command tails after `--` as literal positional input while retaining explicit `--command` compatibility and rejecting mixed forms.
- Consolidate accessibility observer registration, exact element/process dispatch, stop, and deinitialization cleanup under one instance-owned registry.
- Preserve middle and right mouse-button identity across clicks, holds, and drags, and prebuild complete input sequences so allocation failures cannot leave a button held down.
- Refresh AXorcist to refuse element-scoped typing when focus cannot be established, preserve exact PID targets, reject conflicting application/PID selectors, and report point lookup misses as errors.
- Refresh AXorcist point-to-app resolution to keep exact-app misses fail-closed and replace the former ~5-second all-app Accessibility scan with one native on-screen window snapshot; the source-blind exact-head validator measured 43–67 ms for these lookup cases.
- Carry canonical desktop-action outcomes through capability-gated Bridge protocol 1.23 requests, preserving exact refused, partial, unverified, and indeterminate failures while older hosts remain conservative after a response is lost.
- Preserve successful native outcomes for click, type, type sequences, scroll, press, action, and set-value across projected Bridge requests, and expose the validated canonical projection in CLI JSON and human output without changing legacy response payloads.
- Embed one canonical 40-hex source commit in clean stamped CLI and macOS app builds, expose it through `--version --json` and Bridge identity receipts, and leave raw unstamped builds explicitly `unknown`.
- Project canonical desktop-action outcomes into MCP metadata for click, type, scroll, press, action, and set-value successes and failures, preserving exact partial recovery and observation-before-retry semantics without inventing receipts for legacy hosts or collapsing composite setup focus into a no-change leaf.
- Correct `peekaboo bridge --help` and Bridge docs to describe capability-aware reusable-daemon, Peekaboo.app, on-demand-daemon, and local-fallback routing.
- Refuse public raw `press` chords before dispatch unless `--foreground` is explicit, with canonical retry-safe refusal metadata and honest unverifiable foreground results.
- Reject excess positional arguments unless a command declares a variadic tail, while preserving explicit multi-chord `press` sequences.
- Isolate accessibility traversal state per search so repeated long-lived CLI/host lookups cannot skip elements seen earlier.
- Redraw interactive agent chat after height-only terminal resizes so its main-screen viewport stays aligned.
- Centralize native input target receipts, lane ownership, routing, outcomes, validation, feedback, and finalization, and require exact process-generation/window/bounds receipts for background scrolls before dispatch.
- Keep AX-only `see --tree --no-screenshot` independent of capture backends and ScreenCaptureKit ownership while still requiring Accessibility on the selected execution host.
- Reduce reusable-daemon window-tracker MainActor work by retaining only bounds and owner PID, avoiding unused per-window application and Accessibility metadata on every reconciliation pass.
- Keep generated help honest about background coordinate receipts, foreground permissions, type targets, legacy background aliases, and verification predicates; deduplicate permission runtime flags and translate legacy AppleScript denials into native-host upgrade guidance.
- Refresh AXorcist to dispatch native accessibility actions once with typed AX errors and route legacy `AXSetValue` requests through the `AXValue` attribute instead of action discovery.
- Preserve terminal input and rendering across fragmented UTF-8 and bracketed paste, exact literal paste state, display-width-safe Unicode, complete 7-bit/8-bit ANSI string controls and OSC-8 links, styled table truncation, and viewport-bounded Markdown and images; clear removed trailing rows during partial updates, keep stop/restart idempotent, and prevent queued renders from escaping a stopped session.
- Cancel stale MCP SSE readers and fail pending requests when a stream ends or reconnects, and reject unrepresentable audio abort timeouts instead of trapping.
- Make `agent --dry-run` emit a deterministic text/JSON preview with the normalized instruction and explicit zero model/tool/session effects, and reject taskless previews as typed invalid usage before chat/help routing.
- Serialize ScreenCaptureKit ownership across Peekaboo processes for the lifetime of the first explicit local-modern claimant or real SCK caller, with build-bound process-awareness receipts, owner-affine auto/modern routing, current-policy capability checks for every transported engine, and fail-closed rolling-upgrade detection for old Bridge and long-running local processes; explicit classic remains a process-isolated, in-process-SCK-free escape hatch and refuses false-preflight captures unless protected WindowServer metadata independently proves access.
- Keep modern capture inside bounded, coordinator-owned `SCScreenshotManager` calls instead of service-lifetime `SCStream` sessions, eliminating persistent stream overlap and rechecking ownership before every new framework dispatch.
- Preserve negative numeric options, attached long-option values, and option-looking capture-action tails through Commander parsing, while enforcing genuinely required positionals instead of silently accepting incomplete commands.
- Reject invalid `capture live|action` cadence instead of silently clamping or trapping, use post-motion monotonic scheduling, and distinguish sampling attempts/failures, sampled FPS, diff-filtered frames, kept FPS, and postprocessing time in JSON/MCP stats.
- Require remote hosts to advertise per-request desktop-observation capture-engine support before sending explicit modern/classic selections, and keep those selections out of a reusable daemon's inherited environment so later `auto` requests retain their own backend policy.
- Pin process-targeted background typing, paste, clicks, and MCP key sequences to one process generation, rejecting Bridge hosts older than protocol 1.22 instead of letting them ignore the receipt or redirect input to a recycled PID.
- Keep `see --capture-engine` on the selected Bridge host instead of silently moving capture and TCC ownership into the caller; fail before local fallback when no compatible host is available, with `--no-remote` as the explicit caller-local opt-in.
- Keep OCR bounds correct for Retina captures, retain AX mutation/coordinate receipts through OCR merges and snapshot/ROI round-trips, use one bounded fast local recognition attempt for automation, and refuse only provenance-bound semantic OCR IDs as element action targets.
- Report live-capture frame deltas against the previous retained frame, preserve nonzero sub-hundredth percentages in human output, and treat luma geometry changes as 100% full-current-frame motion instead of comparing incompatible pixel coordinates.
- Avoid rereading freshly captured window images from disk when checking for transparent, black, or blank output.
- Resolve standalone exact-window AX-only `see` targets from their live owner and bind results to a process-generation/window receipt before publishing actionable element IDs or a snapshot.
- Retry one passive background observation when its exact capture receipt changes before element detection or output, while leaving mutation-capable observations fail-closed.
- Keep raw SwiftPM CLI `--version` output stable with explicit `unknown` build placeholders instead of reading the original working copy and wall clock at runtime; stamped debug and release builds retain rich link-time metadata.
- Require `action` and `set-value` to resolve through a current or freshly targeted UI snapshot, revalidate exact process/window receipts, and refuse before dispatch instead of falling through to the user's frontmost app.
- Probe Bridge diagnostic sockets concurrently under a one-second per-host deadline with bounded cancellation while preserving runtime selection and candidate order, so `bridge status --verbose` neither accumulates nor inherits a wedged host's full handshake latency.
- Keep `app list --include-hidden` responsive when processes stall metadata reads, preserving exact partial inventory with explicit warnings and unknown hidden state instead of timing out or growing duplicate work behind a wedged process; bulk quit now requires known regular-app metadata.
- Require exactly one CLI/MCP `click` target shape, make the MCP schema require a fresh exact-window receipt for background coordinates, reject PID-only shapes before dispatch, and keep explicit foreground pointer calls discoverable.
- Require explicit `--foreground` consent before `menubar click` can inspect or open global status-item UI; keep `menubar list` read-only and report missing items as typed retry-safe pre-dispatch refusals.
- Preserve semantic AX labels, scalar values, roles, descriptions, enabled/selected state, and bounded value-settable capability through background `see` output, persisted snapshots, and agent summaries instead of reducing controls to generic role names.
- Restrict background app launch to a generation-pinned already-running no-op on a host that advertises the same contract, preserve exact PID selectors and zero-dispatch readiness failures, pin focus/switch/unhide activation to the selected process generation, reject ambiguous selector combinations, and refuse cold launch, document/URL delivery, new instances, relaunch, and unhide before dispatch unless explicit foreground consent is present.
- Stop probing, requesting, advertising, or showing AppleScript Automation permission now that application, Dock, and UI operations use native macOS APIs; remove AppleScript code from shipped executables while retaining legacy wire/error decoding for older Bridge hosts.
- Return generation-pinned CG window inventory promptly when AX enrichment stalls; detached per-process enrichment no longer holds Bridge requests after caller timeout or disconnect.
- Let generation-pinned background PID/window observations use fair process/window read lanes so unrelated app mutations overlap and queued same-process writes run between live frames; unresolved or focus-capable capture remains globally exclusive.
- Report empty live/video capture as `CAPTURE_NO_VALID_FRAMES` with actual-dispatch retry metadata, retain bounded capture/decode causes without laundering cancellation or I/O errors, bound video sampling, and remove incomplete MP4 output on failure.
- Stop the curated `learn` copy from presenting `shell` as a CLI command: it remains a built-in Agent capability but is not in the MCP catalog and has no `peekaboo shell` CLI root.
- Ensure action-command JSON validation failures before dispatch report `effect: refused`, including parser and binding errors.
- Verify app focus against the exact active Workspace PID and visible frontmost-window PID, retry through native AX activation, and report the verified effect as confirmed instead of claiming success for an unfulfilled request.
- Honor explicit `see` timeouts beyond 20 seconds, rerun deadline/incomplete AX retries instead of replaying cache, distinguish incomplete reads from expired deadlines, reject unusable empty truncated AX-only results, and keep CLI/MCP guidance accurate.
- Report unusably empty incomplete AX-only observations as retry-safe, mutation-free `ACCESSIBILITY_INCOMPLETE` failures while preserving true `TIMEOUT` errors and useful nonempty truncated evidence.

## [4.0.0] - 2026-08-10

### Added
- Add `verify` for stable window and element predicates, `tools describe <name>` for on-demand schemas, `app focus`, `window restore`, and launch readiness/open-target controls.
- Add native exact-window background right/double clicks, generation-safe app/window receipts, and cross-process desktop-operation coordination.
### Changed
- Merge `hotkey` into xdotool-style `press` chords, `swipe` into dual-target `drag`, `image` and `inspect-ui` into `see`, and rename `perform-action` to `action`.
- Restructure clipboard, menubar, config, agent, and permission operations into real subcommand trees.
- Standardize durations on bare milliseconds or `ms`/`s`, coordinates on `--at`/`--global`, modifiers on comma-separated lists, and focus controls across interaction commands.
- Standardize JSON on one result envelope with action-only `effect` values after request parsing/classification, actionable error hints, and nonzero exits for failures; pre-dispatch parse/bind failures may omit `effect`.
- Make launch, observation, capture, and targeted input background-first; require explicit foreground consent for focus stealing, global keys, and physical pointer gestures.
- Keep all targeted background input overlay-free even when its target is visible or frontmost; only untargeted or explicitly foreground input may show cursor or input-HUD feedback.
- Make `type` text-only; use `press` for Return, Tab, Escape, Delete, and chord sequences.
- Update Swift Subprocess to 1.0.0, pnpm to 11.21.0, and CI to macOS 26 / Xcode 26.6.

### Removed
- Remove CLI roots `sleep`, `open`, `run`, `commander`, root `list`, `image`, `hotkey`, `swipe`, `inspect-ui`, and `perform-action`, plus retired nested aliases.
- Remove legacy coordinate/unit-suffixed flags, clipboard action dispatch, agent mode flags, compound permission requests, and the `.peekaboo.json` runner format.
- Remove the MCP `list`, `hotkey`, and `swipe` tools plus legacy agent shims; rename MCP `perform_action` to `action`.

### Fixed
- Normalize agent failures and `see` success JSON under the shared result envelope, with nonzero terminal failures, specific validation/credential/session/runtime codes, and no duplicate inner `success` field.
- Add actionable migration hints for removed v4 commands and flags, reject ambiguous press input shapes, and align `see`/`type`/`press` help with the accepted grammar.
- Stop cancelled on-demand daemon idle timers from rescheduling one another after repeated Bridge activity.
- Reject conflicting app/PID and window selectors before focus, observation, or mutation.
- Require explicit `--foreground` for long-press clicks.
- Pin background `press` sequences to one process generation and report partial delivery as retry-unsafe.
- Keep direct `action` and `set-value` targets in the background by default, including web-content discovery, unless `--foreground` is explicit.
- Preserve non-US keyboard characters, reject phantom-success accessibility actions, verify typed values and destructive app/window actions, and keep minimized-window state honest.
- Serialize clipboard-backed paste across processes, restore partial writes, and fail closed before unsafe pasteboard mutation.
- Keep OpenAI Responses tool errors recoverable, return all native tool content items, and restore rich tool summaries in agent output.
- Route contended ScreenCaptureKit work through bounded fallback capture and reject unsafe targetless or ambiguous background input.
- Return exact window-sized pixels from automatic and modern ScreenCaptureKit capture instead of accepting a display-sized transparent canvas, without continuation-leak diagnostics when a quarantined screenshot callback never arrives.

## [3.10.0] - 2026-08-02

### Added
- Add reference-bound image-pixel and normalized MCP click coordinates, building on capture context from @scotthuang in #310.

### Fixed
- Honor cancellation promptly and deterministically in daemon polling and CLI timeout helpers. Thanks @SebTardif for #311.
- Avoid a Swift 6.3 release-compiler crash by reusing the shared timeout race for provider commands.

### Changed
- Update Sparkle to 2.9.5, swift-log to 1.15.0, swift-system to 1.8.0, Swiftdansi to 0.3.0 development, and Tachikoma to current main.

## [3.9.10] - 2026-08-02

### Changed
- Reissue the 3.9.9 CLI payload as 3.9.10 after 3.9.9 shipped without the full live install, capture, and automation verification gate.

## [3.9.9] - 2026-08-02

### Fixed
- OpenAI OAuth (ChatGPT login) sessions with an expired access token but valid refresh token are no longer reported unavailable; `see --analyze`, `image --analyze`, and agent vision route through the Codex Responses OAuth transport. Thanks @scotthuang for #293.
- MCP shell commands now support an opt-in timeout that safely terminates the launch-owned process group and bounds pipe draining without changing the legacy unlimited default. Thanks @SebTardif for #298.

## [3.9.8] - 2026-07-23

### Fixed
- Prevent MCP shell commands from deadlocking when either stdout or stderr exceeds its pipe buffer by draining both streams concurrently. Thanks @SebTardif for #292.

## [3.9.7] - 2026-07-21

### Fixed
- Restore standalone and npm CLI launches on macOS 15 by bundling every Swift back-deployment compatibility library required by the release binary and rejecting dangling compatibility dependencies during release verification. Thanks @gyfis for #291.
- Canceling during a ScreenCaptureKit transient-denial retry sleep now stops before a second capture attempt or permission probe. Thanks @SebTardif for #289.
- Prevent dialog discovery and element traversal from recursing indefinitely when an app reports cyclic accessibility relationships.

## [3.9.6] - 2026-07-19

### Highlights
- The standalone and npm CLIs now use the OpenClaw Foundation Developer ID. macOS treats the changed signer as a new TCC identity, so re-grant Screen Recording, Accessibility, and any Automation access used by direct CLI execution after updating.

### Changed
- Sign and notarize the standalone and npm CLI payloads with `Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)`; the 3.9.6 CLI requires a 3.8+ GUI bridge host, and newer hosts continue accepting transition-era personal-team clients.

## [3.9.5] - 2026-07-18

### Highlights
- Browser coordinate automation now fails closed instead of claiming success when Chrome exposes only non-actionable accessibility containers, and exact-window focus/selection keeps multi-window clicks on the intended window.

### Added
- Add `peekaboo screen list` display enumeration and expose key/frontmost, layer, and accessibility subrole metadata in `window list --json`.

### Changed
- Refresh `chrome-devtools-mcp` to 1.6.0.

### Fixed
- Make coordinate clicking fail closed on generic or unverified accessibility press targets, prefer the app's actual key window over helper panels, and require exact-window focus verification before foreground input.

## [3.9.4] - 2026-07-15

### Changed
- Refresh AXorcist, Commander, Swiftdansi, Tachikoma, and TauTUI to their latest patch releases, including stricter SwiftPM checkout handling for Tachikoma's Commander dependency.

## [3.9.3] - 2026-07-14

### Fixed
- Keep swift-log calls usable from nonisolated code when importing AXorcist under current Swift 6 toolchains.

## [3.9.2] - 2026-07-14

### Fixed
- AX error descriptions remain available to nonisolated automation classifiers under Swift 6.2 strict concurrency.

## [3.9.1] - 2026-07-14

### Changed
- `peekaboo inspect-ui` now accepts the standard `--app` target option used by other desktop commands; `--app-target` remains available as a legacy alias.
- `peekaboo move --smooth` now uses natural eased pointer arcs by default, while `--profile linear` preserves deterministic straight-line travel; explicit `--steps` values are honored and human paths are capped at 96 samples to avoid redundant input events.
- Pointer-movement feedback now follows the real move with a short fading tail and one coalesced overlay instead of replaying a slow, thick line across the screen after the pointer arrives.

### Fixed
- Canceling `peekaboo window close` now propagates through disappearance checks and stops before focus, hotkey, or pointer fallbacks. Thanks @SebTardif for #270.
- Canceling `peekaboo window maximize` now stops frame-settling polls before any additional accessibility reads. Thanks @SebTardif for #271.
- Default action-first clicks now synthesize a real pointer click for SwiftUI segmented tabs, whose accessibility `AXPress` action can report success without changing the selected tab.
- Local `see` now confirms snapshot publication before reporting success, preserving its timeout and failure guarantees when a command-level mutation barrier is active.
- Human pointer paths now use bounded minimum-jerk Bézier motion, land exactly on the requested coordinate, and drive the real drag/swipe event path instead of calculating an organic path and then discarding it for a linear drag.

## [3.9.0] - 2026-07-11

### Added
- `peekaboo agent --model` now accepts GPT-5.6 Sol, Terra, and Luna (`gpt-5.6` selects Sol) plus Claude Sonnet 5.

### Fixed
- Resuming an agent session without `--model` now preserves its credential-free provider-qualified model selection instead of silently switching to the current default; ambiguous legacy sessions fail closed and require an explicit override, automatic taskless piped resumes report failed turns with a nonzero exit, and chat headers show a credential-free saved-model label instead of claiming the current default.
- `peekaboo agent` now treats provider terminal events and cancellation as hard execution boundaries: late or truncated tool calls cannot run, canceled or skipped calls report failed completions, and final `done` / `need_info` reasons remain visible.
- `peekaboo agent --list-sessions` now uses persisted creation and update times for display, ordering, and expiry instead of filesystem timestamps, so atomic saves no longer make old sessions appear new.
- Multi-step Ollama agent runs now preserve native tool-call history and recursive schemas, surface streamed server errors, and fail with a resumable saved session when pending tool work exhausts the validated `1...100` step budget.
- Custom-provider models marked `supportsTools: false` now get actionable agent guidance; `config models-provider` lists configured models offline unless `--discover` is passed, and `--save` preserves existing capabilities, limits, and parameters while keeping newly discovered models tool-disabled until explicitly enabled, including in JSON mode.
- OpenRouter, Together, and OpenAI-compatible GPT-5.6 routes now preserve the 372K context/128K output capability profile, omit unsupported temperature, and recognize routing suffixes such as `:online`.
- Adding a macOS application bundle to the Dock now places it with applications instead of mistaking its on-disk directory for a folder.
- Bare `peekaboo paste` now pastes the current clipboard, while payload-only flags without a payload fail validation even when `--restore-delay-ms` explicitly uses its 150ms default; `list apps` also accepts the `app list` visibility flags and emits preferred snake_case keys alongside legacy keys.
- `peekaboo clean --snapshot` now rejects empty, traversal, nested-path, absolute-path, and symlink snapshot IDs, keeping cleanup confined to one real snapshot folder directly beneath the cache root.
- Invoking `peekaboo daemon start` through `PATH` now relaunches the canonical executable instead of looking for a `peekaboo` file in the current directory, startup errors now distinguish launch failures, early exits, and readiness timeouts, and daemon logs honor `PEEKABOO_CONFIG_DIR`. Thanks @mattash for #231.
- Canceling an app relaunch wait now stops its running-state poll immediately instead of spinning through the remaining timeout budget. Thanks @SebTardif for #230.
- Snapshot-backed MCP actions now synchronize cached application, window, and process metadata across concurrent observation updates and action reads, preventing data races. Thanks @SebTardif for #228.
- Adding a path to the Dock now passes the item directly to `defaults` instead of interpolating it through a shell, preventing shell metacharacters in filenames from being executed. Thanks @SebTardif for #224.
- Concurrent credential and configuration updates now serialize the full load-mutate-persist transaction, preventing distinct updates from overwriting one another. Thanks @SebTardif for #227.

## [3.8.0] - 2026-07-09

### Changed
- The standalone CLI keeps its legacy Developer ID team for compatibility with pre-3.8 GUI bridge hosts, while 3.8 hosts accept both the legacy and OpenClaw Foundation release teams during the signing transition.

## [3.7.1] - 2026-07-05

## [3.7.0] - 2026-07-05

### Added
- The MCP image tool now supports native `max_dimension` downscaling, with inline `format: "data"` captures capped at 1500 pixels by default to reduce payload and model-context overhead. Thanks @jacobjove for #219.

### Fixed
- `peekaboo capture action` now returns within a bounded interval when a child survives termination attempts, preserves graceful TERM handling for timeouts and cancellation, and eventually reaps an abandoned child. Thanks @SebTardif for #215.

## [3.6.0] - 2026-07-04

### Changed
- Agent-skill documentation now defines Peekaboo as the authority for product and workflow guidance while allowing distributors such as OpenClaw to ship release-pinned snapshots with host-specific overlays.

### Fixed
- Bridge hosts now always return a non-empty decodable error when error encoding fails, instead of surfacing EOF or a secondary decode failure. Thanks @SebTardif for #211.
- Snapshot listing and cleanup now propagate lock-open failures instead of treating unavailable storage as an empty snapshot list. Thanks @SebTardif for #212.
- Visual feedback now uses one explicit Core Graphics/Accessibility-to-AppKit coordinate boundary, fixing mirrored or offset click, scroll, trail, swipe, window, dialog, capture, annotated-screenshot, and element-detection overlays across primary and vertically arranged displays without applying Retina scale twice; refreshed element detections also retire stale sheets on screens with no new elements.
- Automation services now route visual feedback to Peekaboo's visualizer instead of silently dropping click, type, scroll, hotkey, swipe, mouse-move, window, menu, dialog, dock, Space-switch, and screenshot-flash animations.
- The typing caption shows typed text verbatim, while secure fields are masked before persistence or display by sampling the delivery focus immediately before every text segment (including Tab-to-password sequences and background typing); `PEEKABOO_VISUALIZER_MASK_TYPED_TEXT=true` masks everything.
- Visualizer overlays now center on their targets, and mouse-trail and swipe coordinates are converted into the correct window-local coordinate space.

### Removed
- Removed the visualizer keyboard-theme setting, which only affected the retired QWERTY typing widget.

## [3.5.4] - 2026-07-03

### Added
- `peekaboo see --analyze` and `peekaboo agent` now accept MiniMax-M3 through the global and China MiniMax routes. Thanks @Tugser for #191.
- `peekaboo see --analyze` and `peekaboo agent` now accept Kimi K2.6 and K2.7 Code models through Moonshot's API. Thanks @Tugser for #192.

### Fixed
- CLI paste now completes and reports clipboard restoration before returning, warning without inviting a retry when delivery succeeded but restoration failed.
- MCP paste now warns without suggesting a retry when clipboard restoration fails after delivery. Thanks @SebTardif for #210.
- MCP inline image capture now returns an explicit error when neither capture nor saved-file fallback contains image data, instead of reporting a successful zero-byte PNG. Thanks @SebTardif for #209.
- Public CLI, agent, MCP, and API guidance now treats runtime element IDs as opaque strings to copy exactly instead of implying role-specific ID shapes. Thanks @coygeek for #194.
- JSON-only `peekaboo see` runs without `--path` now keep required screenshots in snapshot storage instead of leaving files on Desktop or exposing their temporary paths. Thanks @coygeek for #196.

## [3.5.3] - 2026-06-13

### Fixed
- Background element/query/coordinate clicks now pin actions to the requested process and exact window, reject mismatched window/PID selectors and unverifiable snapshots, invalidate implicit latest snapshots without deleting history, and no longer require Event Synthesizing when Accessibility completes the click.
- App launch, open, and inventory commands now use the selected runtime host, fixing sandboxed LaunchServices failures; launch/open preserve `--no-focus` and caller-relative app paths, relaunch preflights and keeps quit/wait/launch in one daemon-held transaction, build-scoped fallback daemons remain reusable and controllable across native/Rosetta execution and executable upgrades, incompatible legacy hosts no longer force sandboxed local fallback, and inventory ignores unrelated input overrides.
- Agent, MCP, script, CLI, and bridge mutations now advance implicit-snapshot watermarks at host-confirmed completion or observation boundaries, keep durable pending barriers across client timeouts/disconnects without hiding the acting command's own snapshot, carry remote script observation certificates, recover safely from PID reuse, ignore unavailable alternate hosts after protecting the selected/local stores, and preserve explicit snapshot history.

## [3.5.2] - 2026-06-13

### Changed
- `peekaboo type` and the MCP `type` tool now default to zero-delay linear typing; supplying `--wpm`/`wpm` still opts into human cadence.

### Fixed
- Synchronized Tachikoma's OpenAI `gpt-5-chat-latest` catalog metadata so configured models apply the correct GPT-5 parameter filtering.

## [3.5.1] - 2026-06-12

### Fixed
- `peekaboo see` now returns at its configured wall-clock deadline when suspended capture or detection work ignores task cancellation, while preserving explicit command cancellation.

## [3.5.0] - 2026-06-12

### Added
- `peekaboo agent` now supports explicit Claude Fable 5 (`claude-fable-5`) selection with 1M context and 128K max output while keeping Anthropic defaults on Opus 4.8 for zero-retention compatibility.

### Changed
- Agent runs now honor the saved `agent.temperature` and `agent.maxTokens` values shared by the CLI and macOS Settings UI, clamp them to each provider's capabilities, infer Fable limits through compatible providers, and omit unsupported sampling parameters for GPT-5 and current Anthropic reasoning models.
- Project, issue, build, release, and app About links now use the canonical `openclaw/Peekaboo` repository.

### Fixed
- Bridge hosts now use atomic lease-backed socket ownership and bounded nonblocking transport, keep Peekaboo.app and the reusable daemon on distinct paths while preserving the healthy app's TCC-backed fallback, preserve lifecycle settings while migrating legacy daemons, prevent MCP from hosting a bridge listener, safely recover stale sockets, and release abandoned client connections instead of wedging. Thanks @Artifact-LV for #184.
- Legacy screen and area capture now fails with a permission or native capture error instead of returning wallpaper-only/redacted pixels from background sessions. Thanks @VishalJ99 for #185.

## [3.4.1] - 2026-06-10

### Fixed
- `peekaboo agent` now resolves saved custom providers, xAI/Grok, Gemini 3.5 Flash, Claude Opus 4.8, and GPT-5.5 model selections before falling back to unavailable built-in defaults. Thanks @udiedrichsen for #182.

## [3.4.0] - 2026-06-07

## [3.3.0] - 2026-06-01

## [3.2.3] - 2026-05-24

## [3.2.2] - 2026-05-22

### Fixed
- `peekaboo agent` now accepts OpenRouter model IDs and can use `OPENROUTER_API_KEY` from env or credentials. Thanks @delort for #155.

## [3.2.1] - 2026-05-18

### Fixed
- `peekaboo click --coords` now treats coordinates as target-window-relative when app/window target flags are supplied, reports resolved target metadata, and requires `--global-coords` for targeted global clicks.
- `peekaboo-mcp` now shuts down cleanly during restart backoff and repairs executable permissions without shelling out through an install path.
- `pnpm run peekaboo:dev` no longer depends on a hardcoded local checkout path.
- `peekaboo agent` now tells models to use the current tool schema instead of stale tool names and arguments. Thanks @vyctorbrzezowski for #139.
- AX element detection now honors traversal budgets and reports truncation when depth, count, or per-node child limits are reached. Thanks @vyctorbrzezowski for #140.
- `peekaboo agent` and MCP clients now have an `inspect_ui` tool for AX-only UI text/control inspection without capturing screenshots. Thanks @vyctorbrzezowski for #141.
- Window-mode capture now falls back to desktop-independent ScreenCaptureKit filters when multi-display setups cannot map a window to an enumerated display. Thanks @lonexreb for #147.
- `peekaboo agent` guidance now routes AX-only observation through `inspect_ui` consistently while keeping screenshot-backed checks on `see`. Thanks @vyctorbrzezowski for #144.
- Custom provider docs, CLI help, and macOS settings now prefer `${VAR}` API key references and shell examples that preserve them literally. Thanks @scotthuang for #142.
- `peekaboo agent` now refreshes desktop context before each model turn and wires opt-in action verification through the configured capture strategy. Thanks @lonexreb for #148.
- AX traversal budgets now have wider defaults plus CLI, MCP, and environment overrides for complex app trees. Thanks @widdowson for #150 and #151.
- `peekaboo agent` now keeps OAuth access tokens on Bearer auth paths instead of misclassifying them as API keys, including config-dir overrides and audio transcription. Thanks @Crux0453 for #154.

## [3.2.0] - 2026-05-15

### Fixed
- Release automation now verifies CLI, npm, macOS app, checksum, appcast, and uploaded GitHub assets before publish.
- `peekaboo type --json` now separates requested text from executed key actions, making escaped special keys such as `\n` visible to agents without losing backwards-compatible `typedText`.
- `peekaboo permissions status --all-sources` now compares Bridge and local TCC permission state side by side, so daemon grants are no longer confused with CLI grants.
- `peekaboo mcp serve --transport ...` now rejects invalid transport names instead of silently starting stdio mode.
- `peekaboo paste --app ...` now fails before mutating the clipboard when the requested app cannot be found.
- `peekaboo agent` no longer sends stale Anthropic extended-thinking options to Claude Opus 4.7 and now exits with failure when agent execution fails.
- Command timeout JSON now reports the intended timeout error instead of occasionally surfacing cancellation as an unknown error.
- Refreshed CLI docs and quickstart examples to use current flags such as `image --path`, `click --coords`, `type --return`, `press --count`, and `scroll --amount`.

### Performance
- Debug CLI startup no longer spawns `git config` on every launch when build-staleness checking is disabled, cutting startup-heavy command latency by more than 30% in local testing.

## [3.1.2] - 2026-05-11

### Fixed
- Release automation now writes artifacts under `build/release` so clean release builds no longer embed `-dirty` in CLI version metadata.

## [3.1.1] - 2026-05-11

### Added
- `peekaboo image --path -` now writes a single captured image to stdout for shell pipelines.
- The npm package now allows Intel Macs when shipping the universal CLI binary.

### Fixed
- Agent tool schemas now preserve MCP `anyOf`/`oneOf` parameters so Gemini no longer rejects `peekaboo agent` requests with orphan `required` entries.
- `peekaboo see --capture-engine cg` now keeps frontmost/window captures on the CoreGraphics path instead of falling through to `SCScreenshotManager`.

## [3.1.0] - 2026-05-10

### Added
- `peekaboo agent --model` now understands GPT-5.5 and Claude Opus 4.7 identifiers, defaults to `gpt-5.5`, and rejects old GPT/Claude model families.
- Automation-oriented CLI commands now auto-start a warm Peekaboo daemon, reuse it across bursty invocations, and let it exit after an idle timeout.
- Bridge protocol 1.5 adds a daemon-side desktop observation operation so screenshot and `see` flows can execute fully in the warm daemon while returning compact metadata.

### Fixed
- MCP stdio servers now default to the local runtime instead of probing an existing Bridge host, avoiding recursive capture timeouts for `see` and `image` tool calls.
- MCP `image` now returns an `isError: true` tool result when Screen Recording permission is missing instead of surfacing an internal server error.
- MCP `analyze` now honors configured AI providers and per-call `provider_config` models instead of hardcoding an OpenAI model.
- Peekaboo.app now signs with the AppleEvents automation entitlement so macOS can prompt for Automation permission.
- The CLI bundle metadata and bundled Homebrew formula now advertise the macOS 15 minimum that the SwiftPM package already requires.
- `peekaboo see --annotate` now aligns labels using captured window bounds instead of guessing from the first detected element.
- Window capture on macOS 26 now resolves native Retina scale from `NSScreen.backingScaleFactor` before falling back to ScreenCaptureKit display ratios.
- `peekaboo image --app ... --window-title/--window-index` now captures the resolved window by stable window ID, avoiding mismatches between listed window indexes and ScreenCaptureKit window ordering.
- `peekaboo image --app ...` now prefers titled app windows over untitled helper windows, avoiding blank Chrome captures.
- `peekaboo image --capture-engine` is now accepted by Commander-based live parsing.
- Concurrent ScreenCaptureKit screenshot requests now queue through an in-process and cross-process capture gate instead of racing into continuation leaks or transient TCC-denied failures.
- Concurrent `peekaboo see` calls now queue the local screenshot/detection pipeline across processes, avoiding ReplayKit/ScreenCaptureKit continuation hangs under parallel usage.
- Natural-language automation examples now use `peekaboo agent "..."`.

### Performance
- `peekaboo see`, `image`, UI interaction, window, menu, dock, dialog, and app commands now prefer the warm on-demand daemon by default, avoiding repeated service startup cost across command bursts.
- `peekaboo tools`, `peekaboo list apps`, `peekaboo app list`, and purely local metadata commands still avoid daemon startup. Pass `--bridge-socket` to target a Bridge host explicitly where supported.
- Daemon-backed screenshot and `see` calls now write screenshot artifacts in the daemon and avoid sending image bytes through Bridge JSON, preventing large-payload timeouts and making warm calls substantially faster.
- Capture engine `auto` now tries the CoreGraphics path before ScreenCaptureKit, which makes repeated screenshot calls faster locally and avoids observed ScreenCaptureKit continuation hangs; explicit `--capture-engine modern` still forces ScreenCaptureKit.
- `peekaboo image --app` avoids redundant application/window-count lookups during screenshot setup and skips auto-focus work when the target app is already frontmost.
- `peekaboo image --app` now uses a CoreGraphics-only window selection fast path before falling back to full AX-enriched window enumeration, reducing warm Playground screenshot capture from about 350ms to 290ms.
- `peekaboo image` skips a redundant CLI-side screen-recording preflight and relies on the capture service's permission check, shaving about 8ms from warm one-shot app screenshots.
- `peekaboo see --app` avoids re-focusing the target window when Accessibility already reports the captured window as focused.
- `peekaboo see` avoids recursive AX child-text lookups for elements whose labels cannot use them, reducing Playground element detection from about 201ms to 134ms in local testing.
- `peekaboo see` batches per-element Accessibility descriptor reads and skips avoidable action/editability probes, reducing local Playground element detection from about 205ms to 176ms.
- `peekaboo see` limits expensive AX action and keyboard-shortcut probes to roles that can use them, reducing Playground element detection from about 286ms to roughly 180-190ms in local testing.
- `peekaboo see` skips a redundant CLI-side screen-recording preflight and relies on the capture service's permission check, shaving a fixed TCC probe from screenshot-plus-AX runs.
- `peekaboo see` now keeps AX traversal scoped to the captured window and skips web-content focus probing once a rich native AX tree is already visible, avoiding sibling-window elements and cutting native Playground detection from about 220ms to 130ms.

## [2.0.2] - 2025-07-03

### Fixed
- Actually fixed compatibility with macOS Sequoia 26 by ensuring LC_UUID load command is generated during linking
- The v2.0.1 fix was incomplete - the binary was still missing LC_UUID despite the strip command change
- Added `-Xlinker -random_uuid` to Package.swift to ensure UUID generation
- Verified both x86_64 and arm64 architectures now contain proper LC_UUID load commands

## [2.0.1] - 2025-07-03

### Fixed
- Fixed compatibility with macOS Sequoia 26 (pre-release) by preserving LC_UUID load command during binary stripping
- The strip command now uses the `-u` flag to ensure the LC_UUID load command is retained, which is required by the dynamic linker (dyld) on macOS 26

### Technical Details
- Modified build script to use `strip -Sxu` instead of `strip -Sx` to preserve the LC_UUID load command
- This ensures the binary includes the necessary UUID for debugging, crash reporting, and symbol resolution on newer macOS versions

## [2.0.0] - 2025-07-03

### Added
- **Standalone Swift CLI** - Complete rewrite in Swift for better performance and native macOS integration
- **MCP Server** - Model Context Protocol support for AI assistant integration
- **Multiple Capture Modes**:
  - Window capture (single or all windows)
  - Screen capture (main or specific display)
  - Frontmost window capture
  - Multi-window capture from multiple apps
- **AI Vision Analysis** - Analyze screenshots with OpenAI or Ollama directly from Swift CLI
- **Configuration File Support** - JSONC format configuration at `~/.config/peekaboo/config.json` with:
  - Environment variable expansion (`${HOME}`, `${OPENAI_API_KEY}`)
  - Comments support for better documentation
  - Hierarchical settings for AI providers, defaults, and logging
- **Config Command** - New `peekaboo config` subcommand to manage configuration:
  - `config init` - Create default configuration file
  - `config show` - Display current configuration
  - `config edit` - Open configuration in default editor
  - `config validate` - Validate configuration syntax
- **Permissions Command** - New `peekaboo list permissions` to check system permissions
- **PID Targeting** - Target applications by process ID with `PID:12345` syntax
- **Homebrew Distribution** - Install via `brew install steipete/tap/peekaboo` for easy installation and updates
- **Comprehensive Test Suite** - 331 tests with 100% pass rate covering all major components
- **DocC Documentation** - Comprehensive API documentation for Swift codebase

### Changed
- Complete architecture redesign separating CLI and MCP server
- Improved performance with native Swift implementation
- Better error handling and permission management
- More intuitive command-line interface following Unix conventions
- Enhanced permission visibility with clear indicators when permissions are missing
- Unified AI provider interface for consistent API across OpenAI and Ollama
- Logger's `setJsonOutputMode` and `clearDebugLogs` methods are now synchronous for better reliability

### Fixed
- Configuration precedence (CLI args > env vars > config file > defaults)
- SwiftLint violations across the codebase
- ImageSaver crash when paths contain invalid characters
- Logger race conditions in test environment
- PermissionErrorDetector now handles all relevant error domains
- Test isolation issues preventing interference between tests
- Various edge cases in error handling and file operations

### Removed
- Node.js CLI (replaced with Swift implementation)
- Legacy screenshot methods

## [1.1.0] - 2024-12-20

### Added
- Initial TypeScript implementation
- Basic screenshot capabilities
- Simple MCP integration

### Changed
- Various bug fixes and improvements

## [1.0.0] - 2024-12-19

### Added
- Initial release
- Basic screenshot functionality
