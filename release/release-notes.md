## [4.2.2] - 2026-08-20

### Highlights

- **Background automation is more capable and safer.** Exact-window middle and triple clicks never move focus or the cursor, while keyboard, menu, window, and app actions refuse ambiguous or incomplete targets.
- **Previously invisible controls and windows work again.** Editable TextEdit document areas remain discoverable, and exact minimized or off-Space windows stay resolvable.
- **Agent behavior is easier to understand and control.** Dry runs explain requested and effective foreground authority, and guidance accurately describes safe background typing, shortcuts, and dialog input.
- **Long-running automation stays responsive and predictable.** AX observers, command deadlines, and VibeTunnel title helpers are bounded; input is never blindly replayed; Bridge handshakes are reused; SSH terminal input remains reliable; and deployment avoids Xcode provisioning stalls by building unsigned before manual signing.

### Added
- Add exact-window background middle and triple clicks to CLI and MCP without activating the target or moving the cursor.
- Show requested and effective foreground authority in `agent --dry-run` text and JSON without invoking models, tools, or sessions.
- Add authenticated `peekaboo bridge receipt validate` with the live host's source commit and negotiated protocol metadata.
- Add Bridge protocol 1.30 application and window inventories that distinguish complete from partial evidence while retaining conservative compatibility with older hosts.
- Add an embedding-only exact-window held-pointer API with owner receipts and generation-safe cleanup.
- Add a capability-gated protocol 1.31 Swift Bridge API for signed background-only Agent execution; its qualification CLI remains private and hidden.

### Fixed
- Pin background type, paste, press, targeted clicks, and app, window, or menu mutations to one exact process and window generation; refuse fuzzy, ambiguous, stale, or incomplete targets before dispatch.
- Keep TextEdit document fields and other editable controls discoverable when optional Accessibility attributes are unavailable.
- Resolve exact minimized and off-Space windows without treating unreadable WindowServer catalogs as proof that a target is absent.
- Preserve exact signed read-only selectors across application names, PIDs, bundle or executable paths, and window IDs or titles; reject contradictory evidence.
- Report application and window inventory completeness honestly while keeping complete AX-only listings usable without Screen Recording.
- Pin foreground menu listing and clicks to the exact process and window, preserving truthful focus outcomes.
- Prevent duplicate scrolling and SwiftUI tab presses after accepted input; preserve exact dispatch counts and require fresh observation before retrying.
- Return target-attributed, retry-unsafe outcomes when an accepted Accessibility `set-value` write cannot be verified.
- Clean up cancelled held shortcuts and pointers only against their original process generation.
- Return structured connection and discovery errors instead of crashing on malformed persisted custom-provider URLs. Thanks @SebTardif for #488.
- Bound wedged VibeTunnel terminal-title helpers and fall back to ANSI title updates. Thanks @SebTardif for #489.
- Explain actionable `set-value`/`set_value` recovery for unfocused background windows.
- Align Agent, MCP, CLI, and documentation around snapshot-pinned background input, targeted dialog entry, and explicit foreground consent.
- Bound AX observer registration and removal, and preserve Realtime completion, cancellation, and timeout outcomes. Thanks @SebTardif for AXorcist #46/#47 and Tachikoma #68.
- Keep CLI wall-clock command deadlines bounded even under sustained executor load.
- Reuse authenticated Bridge handshakes and explain implicit-host rejection before falling back locally.
- Reject empty interaction commands, targetless background typing, malformed browser requests, and invalid video inputs before runtime discovery while explicit help still succeeds.
- Preserve JSON flags after `--` as child-command arguments.
- Preserve Option/Meta chords and fragmented escape sequences across higher-latency SSH connections.
- Build deployment companion apps unsigned, then apply the Foundation signature manually before transactional installation to avoid Xcode provisioning stalls while preserving exact signer and TCC identity.
