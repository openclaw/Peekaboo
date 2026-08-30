---
summary: 'Reference matrix for Peekaboo macOS, Swift, Xcode, and Node requirements.'
read_when:
  - 'checking whether a macOS version or toolchain can run Peekaboo'
  - 'updating install, build, release, or package compatibility docs'
---

# Platform support

This page collects the platform requirements surfaced by Peekaboo's package, project, CI, and install metadata so
install, build, and release docs do not drift. It is descriptive, not an additional guarantee that every listed
combination is continuously tested.

| Surface | Minimum | Notes |
| --- | --- | --- |
| Released CLI and MCP package | macOS 15.0+ | The CLI package target is [`Apps/CLI/Package.swift`](../Apps/CLI/Package.swift), which declares `.macOS(.v15)`. The npm package wraps the same CLI binary. |
| macOS app | macOS 15.0+ | The Xcode project [`Apps/Mac/Peekaboo.xcodeproj/project.pbxproj`](../Apps/Mac/Peekaboo.xcodeproj/project.pbxproj) sets `MACOSX_DEPLOYMENT_TARGET = 15.0`. The app's SwiftPM package metadata still declares `.macOS(.v14)` for package resolution. |
| Public SwiftPM libraries | macOS 14.0+ package metadata | The root [`Package.swift`](../Package.swift) exports `PeekabooFoundation`, `PeekabooProtocols`, `PeekabooAutomationKit`, and `PeekabooBridge` without pulling in the agent runtime or Tachikoma. Internal core package manifests also declare `.macOS(.v14)`, but host features that capture screens, inspect windows, control Spaces, or drive Accessibility follow the CLI/app requirements. |
| CLI source builds | macOS 15.0+, Swift 6.2+ toolchain; Python 3.9+ for workspace setup | The CLI manifest declares `.macOS(.v15)` and `swift-tools-version: 6.2`; maintainers and CI use Xcode 26.x or newer when available. Initialize submodules and run the [checkout-local setup](building.md#commander-dependency-resolution) before direct Swift or Xcode development. Older Xcode fallback paths in [`.github/workflows/macos-ci.yml`](../.github/workflows/macos-ci.yml) do not lower the SwiftPM toolchain requirement. |
| pnpm helper scripts | Node.js 22+ | [`package.json`](../package.json) declares `engines.node >=22.0.0`. Node is required for docs/build/release helper scripts and for the npm MCP wrapper; core Swift builds do not require Node. |

If a doc mentions platform support, prefer linking back here instead of restating a separate compatibility matrix.
