---
summary: 'Reference matrix for Peekaboo macOS, Swift, Xcode, and Node requirements.'
read_when:
  - 'checking whether a macOS version or toolchain can run Peekaboo'
  - 'updating install, build, release, or package compatibility docs'
---

# Platform support

This page collects Peekaboo's public platform requirements so install, build, and release docs do not drift.

| Surface | Minimum | Notes |
| --- | --- | --- |
| Released CLI and MCP package | macOS 15.0+ | The CLI package target is [`Apps/CLI/Package.swift`](../Apps/CLI/Package.swift), which declares `.macOS(.v15)`. The npm package wraps the same CLI binary. |
| macOS app | macOS 15.0+ | The Xcode project [`Apps/Mac/Peekaboo.xcodeproj/project.pbxproj`](../Apps/Mac/Peekaboo.xcodeproj/project.pbxproj) sets `MACOSX_DEPLOYMENT_TARGET = 15.0`. The app's SwiftPM package metadata still declares `.macOS(.v14)` for package resolution. |
| Core Swift packages | macOS 14.0+ package metadata | Root and core package manifests such as [`Package.swift`](../Package.swift) and [`Core/PeekabooCore/Package.swift`](../Core/PeekabooCore/Package.swift) declare `.macOS(.v14)`, but host features that capture screens, inspect windows, control Spaces, or drive Accessibility follow the CLI/app requirements. |
| CLI source builds | macOS 15.0+, Xcode 16.4+ / Swift 6.2 | The CLI manifest declares `.macOS(.v15)` and `swift-tools-version: 6.2`; CI selects Xcode 26.x when present and falls back through Xcode 16.4 in [`.github/workflows/macos-ci.yml`](../.github/workflows/macos-ci.yml). |
| pnpm helper scripts | Node.js 22+ | [`package.json`](../package.json) declares `engines.node >=22.0.0`. Node is required for docs/build/release helper scripts and for the npm MCP wrapper; core Swift builds do not require Node. |

If a doc mentions platform support, prefer linking back here instead of restating a separate compatibility matrix.
