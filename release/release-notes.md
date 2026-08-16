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
- Add Bridge protocol 1.26 exact browser connection receipts, binding persistent Chrome DevTools MCP sessions to one process generation or validated loopback DevTools browser identity.
- Add Bridge protocol 1.25 one-shot dialog receipts that uniquely bind an exact process/window, raw dialog or sheet, and semantic AXPress button for background click/dismiss, with read-only targeted listing and canonical postcondition outcomes.
- Add a background-first native Bridge host runtime for signed macOS apps, with explicit caller allowlists, shared mutation/snapshot state, checked lifecycle, and no Core, provider, browser, daemon, or AppleScript surface.
- Add capability-gated exact-window background wheel delivery for opaque WKWebView/Tauri scroll targets, preserving the foreground app and physical cursor while refusing hidden, stale, Electron, Chromium, Catalyst, or AX-only routes.

### Changed
- Build branded release disk images from pinned direct Finder-metadata tooling, preserving the signed and notarized drag-to-Applications layout without GUI automation.

### Fixed
- Keep Finder layout metadata on the DMG volume instead of the signed app bundle, preserving strict mounted-payload code verification without losing the branded drag-to-Applications layout.
- Complete the Bridge 1.29 receipt-session handshake before daemon status or stop control, validate explicit move snapshots before focus setup, and preserve actionable quit recovery over generic escalation guidance.
- Require explicit foreground consent for Space switching and followed window moves across CLI and MCP, and compose their native move/switch receipts without synthesizing success or dispatch counts.
- Establish and verify a window's destination Space before removing prior memberships, and retain its exact generation-bound identity through Space-aware focus.
- Let later exact maximize readbacks supersede transient poll errors while preserving cancellation and identity contradictions, and route idempotent no-change receipts by the actual execution host.
- Return canonical retry-safe pre-dispatch refusals when window owner-generation or bounds-provenance evidence does not match the selected mutation target.
- Bind protocol 1.29 window and frontmost capture receipts to the exact captured process/window, reject missing or contradictory target metadata, and keep screen/area captures explicitly global.
- Keep root help and version order-independent across canonical kebab- and camel-case runtime-option aliases while preserving correct missing-value errors.
- Treat `capture video` as caller-local media ingestion so valid files and typed media failures bypass Screen Recording and ScreenCaptureKit-owner preflight while live capture remains gated.
- Refuse exact-window and dialog Accessibility reads when macOS cannot arm their per-element messaging deadline, and surface timeout reset failures instead of continuing unbounded.
- Treat Finder's role-inapplicable `AXWindow` value failure as sparse descriptor data so normal exact-window combined observations retain usable Accessibility elements, while every other hard AX read and genuinely incomplete window remains fail-closed.
- Refuse exact-window combined observations when Accessibility returns no usable elements, preserving the requested raster and retry-safe `ACCESSIBILITY_INCOMPLETE` semantics across current and legacy Bridge hosts while explicit screenshot-only capture remains successful.
- Validate request-only `click`, `move`, `type`, and `drag` arguments before runtime-host selection so malformed requests cannot be masked by Bridge availability or trigger unnecessary host startup.
- Keep concrete interaction snapshots out of ScreenCaptureKit-owner preflight because they cannot refresh or capture, and give omitted/latest snapshot flows an actionable `see --capture-engine classic` recovery.
- Add Bridge protocol 1.26 explicit-reference-only coordinate receipts for exact-window `see --no-elements`, making the documented background coordinate-click workflow consumable without Accessibility traversal or replacing the prior implicit element snapshot while older hosts fail before receipt allocation.
- Honor cancellation while draining and reaping MCP ShellTool subprocesses so canceled commands cannot linger behind pipe cleanup. Thanks @SebTardif for #454.
- Reject unknown and non-object MCP `tools/call` arguments as JSON-RPC invalid params before policy checks or tool dispatch, recursively honoring the closed schemas advertised by `tools/list`.
- Probe Chrome before reporting browser connection success, reject ambiguous same-channel profiles, preserve structured Bridge failures, never silently rediscover another profile after a session or endpoint is lost, and atomically focus the exact snapshot uid before browser typing or key presses.
- Stage browser uploads from race-checked, current-user regular files into one private per-session Chrome MCP temporary root, without unrestricted filesystem access, and terminate the exact child before cancellation cleanup.
- Classify an exact standard window with a live attached sheet as dialog-active during observation, sharing native role evidence with dialog actions while keeping the parent window receipt exact.
- Report exact ScreenCaptureKit owner PID, process generation, safe build identity, and selected-versus-owner Bridge sockets when available; automatic capture can still use an owner-aware host's classic-only path around an auxiliary legacy owner, while explicit modern and ambiguous legacy ownership remain fail-closed without unsafe process-stop guidance.
- Centralize canonical application/window outcomes across Foundation, services, Bridge, CLI, and MCP while preserving legacy JSON fields and v4.1.0 public APIs, and keep minimize verification exact when retained AX window IDs disappear transiently.

### Verification

- Source: [809630e4e10c452644239d7be5d495241bb3cee2](https://github.com/openclaw/Peekaboo/commit/809630e4e10c452644239d7be5d495241bb3cee2) — GitHub-verified release commit.
- npm: [@steipete/peekaboo@4.2.0](https://www.npmjs.com/package/@steipete/peekaboo/v/4.2.0)
- Registry tarball: [peekaboo-4.2.0.tgz](https://registry.npmjs.org/@steipete/peekaboo/-/peekaboo-4.2.0.tgz)
- npm integrity: `sha512-ImBijaPupQwhi2m8Wj2uZfYGPIui5gFC7Dd5oXBI6Od7FxRtXu3mSPcJGqNskC5knUiNYIBDWuvRoIBOKas0tw==`
- npm published: `2026-08-16T13:55:36.756Z`; `latest` resolves to `4.2.0`.
- Tests: `pnpm run test:safe`, `pnpm run test:automation` (987 Core, 99 runtime, and 765 automation tests), and `scripts/test-create-release-dmg.sh` passed on the release commit.
- Artifact proof: the universal CLI, npm CLI, app zip, and branded DMG embed the release commit; Foundation Developer ID signing, nested-code verification, online notarization, stapling, Gatekeeper, checksums, mounted-DMG layout/xattr checks, and Sparkle enclosure verification passed.
