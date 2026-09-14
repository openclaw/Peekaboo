## 4.4.0 - 2026-09-13

**Highlights:** Capture works again next to Claude/OpenClaw, hosts embedding PeekabooMCPServer can supply their own MCP transport, and Chrome DevTools MCP 1.9.0 no longer activates DevTools during background reads.

- Capture no longer refuses when other apps such as Claude or OpenClaw are running; scope ScreenCaptureKit coordination to Peekaboo hosts and preserve real capture errors.
- Let hosts embedding `PeekabooMCPServer` supply their own MCP transport with the same completion and cleanup lifecycle as stdio. Thanks @semyoren! #716.
- Update Chrome DevTools MCP to 1.9.0 with a verified telemetry opt-out patch that prevents background reads from probing or activating DevTools; preserve single-file uploads across the provider's new array schema and re-audit browser routing.
- Fix host-routed screen observations with Accessibility elements by validating their semantic owner separately from the screen raster target. #715, #710.
- Keep caller screenshot destinations intact when remote evidence is rejected or raw output was not requested, staging ordinary captures before file publication as well as ROI captures. #710.
- Fix application name and bundle resolution being blocked by reaped processes lingering in LaunchServices; require repeated native absence while retaining refusal for uncertain or changing process identities. #709.
- Keep background window close, restore, and maximize callbacks on the main thread when the target belongs to the Peekaboo host, preventing embedded macOS apps from crashing while preserving exact-window validation and remote AX deadlines.
- Keep action capture running until it samples after the child finishes and retain exact sample-boundary proof in new manifests; capture caps still fail incomplete coverage, while older version-1 manifests remain readable as legacy elapsed-time evidence.
- Clarify observation evidence failures and runtime refusal guidance so same-build verification errors do not imply that an update will fix them. #710.
- Strengthen selected-CLI guidance checks, repair published guide links, restore the read-only clipboard example, run guidance checks in regular macOS CI, and make noncooperative detection timeout proof independent of scheduler timing.
- Update Linux validation to Swift 6.3.3 and CI plus the pinned qualification runtime to Node 26.8.2 with verified universal binary checksums; smoke-test the built CLI catalog in CI.
