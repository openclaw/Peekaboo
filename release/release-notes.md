## 4.6.0 - 2026-09-25

**Highlights:** Safer typing and bounded clipboard/desktop waits, restored Codex MCP and GUI Bridge connections, explicit background typing strategies, and optional Agent desktop context.

- Clear inherited modifier flags from targeted Unicode typing so held Command, Shift, or other modifiers cannot turn literal text into shortcuts.
- Clear foreground chord modifier flags on key-up, including cancellation cleanup, and preserve retry-unsafe dispatch receipts for interrupted holds. Thanks @jandubois! #797.
- Clear inherited modifier flags from unmodified foreground typing special keys without changing their keycodes or unverified delivery outcomes.
- Bound paste clipboard-restoration waits to 10 seconds so excessive delays cannot monopolize the shared paste lock; CLI and MCP callers using longer delays must reduce them. Thanks @SebTardif! #759.
- Bound clipboard-backed paste admission to one 15-second monotonic deadline across in-process and file-lock waits; refuse late acquisition with retry-safe `TIMEOUT` before clipboard or input changes, while preserving admitted settle and restoration. Thanks @SebTardif! #793.
- Bound desktop operation lane admission to a shared 15-second deadline across turnstiles and scoped locks; refuse late acquisition before dispatch while preserving earlier effects and admitted operation lifetimes. Thanks @SebTardif! #794.
- Bound targeted dialog hierarchy discovery off the main actor using the caller's timeout, preserving large/deep trees and exact receipts; reject late candidates and report timeout or incomplete Accessibility evidence with specific error codes.
- Bound selected-dialog metadata extraction to the targeted list's remaining timeout without blocking the main actor or accepting late results; read native text values directly while preserving optional metadata defaults and exact dialog discovery.
- Accept structured MCP experimental capabilities during initialization, restoring Codex connections; pin the upstream decoder repair and document its Swift dictionary-type migration. Thanks @Wudib! #745.
- Restore default MCP startup on explicitly selected GUI Bridge hosts that support isolated browser sessions, preserving capability checks and caller-owned session cleanup. Thanks @smhanov! #744.
- Refuse ordinary CLI typing and MCP clicks, actions, value changes, snapshot-backed scrolling, typing, and key presses from consumed or pending snapshots before focus or input; centralize mutation-lease handling while preserving historical reads and existing modifier-click/pixel-focus ownership.
- Route background typing in web fields directly through targeted keyboard events, including clear and editing keys, instead of accepting ignored Accessibility writes; refuse unproven routes before input.
- Bind receipt-pinned Accessibility typing, clear, and editing-key writes to the native receiver selected by focus validation; refuse last-moment receiver changes before mutation or keyboard fallback while preserving continuation reflow.
- Bind background Cmd+A selection to its retained exact-window receiver, refusing changed or unreadable receiver identities before writing or replaying input.
- Preserve known typing prefixes and zero-input refusal receipts when shared Accessibility setters fail, without replaying input or changing typing strategy.
- Honor background typing strategies for text, editing keys, and clear; make the native-AX-first default explicit as `actionFirst`, keep synthetic-only choices free of AX value/selection edits, and refuse ambiguous AX failures without duplicating input through keyboard fallback. Preserve legacy SDK keyboard delivery by default; explicitly selected AX replacement requires zero delay and a freshly verified already-focused named target, while foreground CLI keyboard behavior is unchanged.
- Distinguish Agent narrative from recorded action outcomes with bounded runtime notices in CLI JSON, non-quiet completion output, and MCP; preserve quiet text, original outcomes, and successful workflow semantics when later observations verify effects.
- Add `agent --no-desktop-context` to skip new automatic desktop-context collection for run, chat, and resume invocations while preserving saved history, tool access, and background authority.
- Honor MCP query-click waits with fresh, receipt-pinned Accessibility reads without screenshots; refuse changed targets and late matches while preserving the original modifier-click authority. Thanks @SebTardif! #785.
- Expose already-observed focus identity in `see --json` and `see`/`inspect_ui` MCP metadata without extra Accessibility reads, preserving unknown focus and existing input guards.
- Distinguish Bridge handshake success, permissions, advertised capture support, and ScreenCaptureKit preparation in normal and verbose status output without changing capture admission or JSON reports. Thanks @ProActive2023! #748.
- Stop reporting hidden windows as on screen when native visibility metadata is omitted or as minimized in text listings; align native and classic capture metadata while preserving exact-window targeting and partial-inventory diagnostics. #779.
- Preserve sanitized partial Agent execution traces when the step limit is exhausted, keep no-cache runs non-resumable, and replace blind-retry guidance with current-state inspection; retain Peekaboo-owned snapshot-cleanup metadata while isolating legacy browser-provider claims.
- Centralize browser batch-progress validation for signed and legacy receiptless Bridge results while preserving their separate connection and completion-evidence requirements.
- Keep fresh local `see` snapshots eligible for subsequent background input by excluding read-only observation timeouts from mutation barriers; preserve barriers for web-focus/menu-opening observations and caller-owned mutations.
- Skip capture-owner startup probes for Agent invocations with an explicit tool allow-list that cannot reach native capture and no visual enhancements, reusing MCP catalog policy while preserving host routing and snapshot safety.
- Preserve returned process and exact-window target identities and receipts in successful MCP typing metadata, including pixel-focus typing.
- Bind signed `set-value` results to the same typed native observation, preserving numeric tolerance, literal text, and old-client presentation while rejecting fractional Boolean readbacks and lossy decimal-to-integer requests before claiming success.
- Preserve exact-window snapshot receipts for background CLI element/query clicks on capable hosts without requiring redundant window flags; retain the process-pinned contract on limited hosts, share target planning across click variants, and reject contradictory or incomplete exact-window receipts.
- Resolve ambiguous background focus observations using a stable native application receiver matched to one captured element, while preserving exact-window ownership, live input validation, and ordinary traversal time when the optional initial focus read stalls; later menu-bar reads retain their normal remaining-deadline budget.
- Explain missing or ambiguous observed focus in `see --verbose` using content-free capture diagnostics without extra Accessibility reads or changed input guards.
- Clarify that ScreenCaptureKit process-owner receipts omit Bridge socket paths rather than proving a listener absent or unreachable; document capture-runtime participation by embedding apps without changing routing or ownership guards.
- Preserve the legacy SDK's `synthFirst` typing default while background typing remains AX-first; explicit strategies retain their precedence, and explicit SDK AX replacement rejects web or unprovable receivers before value mutation.
- Prefer the best renderable window for daemon-backed app-only foreground focus while preserving exact selectors, receipt validation, and the fallback when every window is non-renderable. Thanks @jandubois! #802.
- Resolve background keyboard focus through the native owning-window link when web text fields do not expose a direct window ID, preserving exact process, window, and focus validation.
- Keep Agent text-task dry-run previews independent of UI hosts, capture ownership, and permissions while preserving input validation and foreground-authority reporting. #776.
- Preserve typed desktop-action timeout, snapshot, and element error codes consistently across CLI JSON renderers without changing prior-effect or retry-safety metadata. #793.
- Preserve implicit observations after canonical no-dispatch paste refusals, including wrapped target-resolution failures, when no focus or clipboard effect occurred; retain conservative invalidation for stronger outcome evidence, partial clipboard writes, and uncertain input and preserve other operations' pending barriers.
- Exclude twice-confirmed absent processes from read-only application inventory while keeping denied, unavailable, and changing identities partial. Thanks @SkidCentrel! #784.
- Limit ambiguous application suggestions to tied matching names and PIDs instead of exposing the entire running-app inventory, while keeping selector ambiguity fail-closed.
- Let Agent and MCP automatic observations use proven classic capture on an explicitly selected ready Bridge while another process owns ScreenCaptureKit; keep explicit modern and raw SCK-only requests refused before transport. #778.
- Restore reliable background scrolling by preferring owned numeric scrollbars, while keeping page fallback after definite value rejection and stopping after ambiguous input; eligible targets now use scrollbar increments instead of page distances.
- Preserve existing background Cmd+A selection receipts as one unverified Accessibility value mutation through exact-window CLI/MCP checks; stop on ambiguous AX errors without replay. Input-strategy and hold behavior are unchanged.
- Allow verified foreground focus after native AXRaise reports an unsupported action or attribute, without inventing a raise dispatch; preserve earlier accepted mutations and stop on ambiguous AX errors. Thanks @jandubois! #801.
- Avoid downloading CLI CI build caches that are immediately discarded; key reusable dependency state by toolchain, manifests, locks, and submodules instead of every commit.
- Align internal and public SwiftPM consumers on AXorcist 0.1.11 to preserve native numeric values, improve geometry/range parsing, and reject invalid scroll amounts before input dispatch.
- Avoid duplicating native tool observations in Agent context while preserving action safety metadata, verification receipts, and image attachments.
- Avoid reading geometry for unrelated Accessibility roles during exact-window keyboard focus checks, preserving per-character receiver validation.
- Remove retired internal MCP process-only target resolution and obsolete window-target rejection; keep process-generation coverage on the active shared keyboard planner.

- Update subprocess integration guidance for background-first host routing, producer-bound snapshots, shell-free Node.js calls, and structured failures without automatic input replay.

### Compatibility

- Propagate ambiguous application running-state checks instead of reporting matching apps as stopped; direct Swift `ApplicationService` callers must now use `try await`. Thanks @SebTardif! #795.
