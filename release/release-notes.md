## 4.8.0 - 2026-10-03

**Highlights:** Add exact-window background drag to the CLI and MCP, make background rich paste work in freshly launched windows and fence it against concurrent clipboard changes, extend background scrolling to Safari, report date-valued controls in observations, and recover capture readiness after slow startup checks.

- Add bounded exact-window background drag to CLI and MCP using one held-pointer owner, generation-bound last-point cleanup, and protocol-1.39 receipts; preserve explicit foreground gestures and report unverified retry-unsafe delivery without claiming the drop succeeded.
- Report missing background-drag source and destination IDs as explicit retry-safe, zero-dispatch `ELEMENT_NOT_FOUND` refusals without inventing receiver receipts or changing foreground error semantics.
- Preserve captured focused-element evidence in signed background-drag target attribution, avoiding false receipt failures while retaining unverified delivery and retry-unsafe outcomes.
- Prepare exact standard background windows for temporary rich/binary paste using observed blank chrome and retained editor state, preserving clipboard ownership, foreground isolation, owed releases, and truthful composite receipts through Bridge protocol 1.41. #877.
- Fence temporary exact-window background paste with the retained clipboard write generation, refusing unsupported hosts before writing and stopping new key-downs after another copy while preserving owed key releases and newer clipboard contents.
- Report failed background rich-paste preparation observations as no-input refusals, preserving earlier clipboard/preparation effects and avoiding misleading claims that a focus request was sent.
- Add explicit `--allow-temporary-clipboard` authority for Agent and public MCP to paste bounded base64 payloads through fresh exact-window snapshots while keeping UI background-only, requiring fresh resume opt-in, preserving ownership-aware cleanup and retry-unsafe receipts, and retaining nested/managed Agent attenuation.
- Preserve input-delivery and message-only refusal causes across composed background preparation outcomes, including content-free native chrome observation diagnostics, without changing dispatch or retry safety.
- Recognize Safari's framework-linked executable and scroll-area containers for eligible exact-window background wheel dispatch, preserving hidden-app exclusions, exact receipt checks, and unverified retry-unsafe outcomes.
- Preserve native Accessibility date values as ISO-8601 UTC timestamps in UI observations instead of silently omitting them, including Calendar's date-valued controls.
- Recover ScreenCaptureKit readiness when a slow startup safety scan later completes, preserving fail-closed capture while pending or failed and the existing per-capture ownership checks.
- Validate Bridge Agent and live certification-producer executables against the running universal-binary slice, avoiding false identity refusals while preserving exact code, path, process-generation, file, and peer-trust checks.
- Redact inline base64 payloads from Agent live tool-call previews, including nested and partially streamed values, without changing authorized tool input.
- Preserve known clipboard cleanup status through Agent paste errors and public MCP metadata, keeping provider claims isolated and canonical dispatch, target, and retry semantics unchanged.
- Preserve plain and attributed Accessibility value labels in menu listing, path selection, and menu-extra matching, keeping title precedence and ambiguous-name refusals unchanged.
- Preserve retry-safe no-dispatch outcomes for background wheel failures before the first event, including stale or out-of-window geometry, without weakening accepted-prefix or uncertain-delivery failures.
- Preserve unsupported background scrolls as exact-target, retry-safe no-dispatch refusals through Bridge instead of reporting a possible mutation or implying all background scroll is Accessibility-only.
- Preserve reported receiver receipts in MCP background scroll errors without changing retry safety, snapshot invalidation, or foreground global-input attribution.
- Preserve reported process-generation and exact-window receipts in CLI and MCP paste errors after unconfirmed targeted input, without changing retry safety or attributing shared clipboard effects to a window.
- Report conflicting concrete snapshot and target selectors in `set-value` and `action` as retry-safe, non-dispatched `INVALID_INPUT` refusals instead of unknown, unverifiable errors; clarify the targeting alternatives.
- Preserve Bridge route, reported target receipts, hints, and causes on typed stale-snapshot CLI refusals instead of replacing them with local errors; keep snapshot-consumption and finalization safeguards unchanged.
- Keep app-launch bundle paths and selector proofs consistent across canonical spellings, fixing background verification under `/private/tmp` while preserving process-generation, ambiguity, and caller-local alias checks.
- Fix Bridge verification when macOS hides the caller's window title, preserving exact process/window identity, fresh Accessibility reads, and strict signed-receipt validation.
- Reuse normalized Agent tool-result claims when building execution traces, eliminating duplicate canonical validation while preserving failure, dispatch, and redaction semantics.
- Clarify that `see` pixels and Accessibility metadata are not acquired atomically, and explain how to verify an asynchronous action without replaying it.
- Explain when listed windows are rejected by coordinate-target eligibility without exposing their titles or changing the filters, and preserve already-completed setup focus plus the later refusal diagnostic in cursor-move errors. #869.
- Explain that exact-window paste capability refusals can result from custom-socket Bridge trust limits, not only an outdated host, without changing trust or retry behavior.
- Clarify that deprecated `app launch --no-focus` is a compatibility no-op: default launch only verifies an already-running app, while cold launch still requires explicit foreground consent.
- Clarify that foreground `paste` does not confirm receiver consumption, explain how to inspect an unconfirmed paste outcome instead of replaying it, and add a charset-safe HTML hyperlink paste example. Thanks @marcoantoniofassa! #885.
- Refresh Playground testing guidance for v4 inventories, signed fixtures, fresh exact-window snapshots, and background outcome verification without input replay.
- Bind companion-app installation and rollback quits to verified exact-path process generations, refusing ambiguous targets, inspection failures, and uncertain retries without raw PID signals. #874.
- Bound ScreenCaptureKit process-safety signing inspections to two concurrent workers across censuses, preserving complete blocker collection, identity checks, registration retries, and fail-closed readiness.
- Sign debug CLI builds with the canonical Peekaboo CLI identifier so they satisfy existing GUI Bridge and deployment healthcheck identity checks.
- Repair first-party GUI qualification by admitting the signed controller and validating canonical global/window receipt scopes; preserve exact authenticated inventory binding and avoid repeating an acknowledged owner disconnect after an evidence error.
- Remove idle certification-coordinator exit delays by clearing completed child-wait timers and their listeners, preserving normal output draining and bounded TERM/KILL cleanup.

### Compatibility

- Exact-window background drag requires a GUI Bridge host at protocol 1.39, and exact-window background rich/binary paste now requires the clipboard-fenced protocol 1.40 path (cold-window preparation uses 1.41). With an older Peekaboo app as the Bridge host, these refuse before any clipboard write or input; update the app together with the CLI.
