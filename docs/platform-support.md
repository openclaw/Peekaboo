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
| Released CLI and MCP package | macOS 15.0+ | The CLI package target is `Apps/CLI/Package.swift`, which declares `.macOS(.v15)`. The npm package wraps the same CLI binary. |
| macOS app | macOS 15.0+ | The app target ships with a macOS 15 deployment target and uses newer SwiftUI/AppKit APIs behind availability checks where needed. |
| Core Swift packages | macOS 14.0+ package metadata | Several library packages still declare `.macOS(.v14)` so package consumers can resolve the modules, but host features that capture screens, inspect windows, control Spaces, or drive Accessibility follow the CLI/app requirements. |
| Source builds | macOS 15.0+, Xcode 16.4+ / Swift 6.2 | Newer macOS/Xcode versions are used by maintainers and CI, but they are not the public minimum unless a specific build path says so. |
| pnpm helper scripts | Node.js 22+ | Required for docs/build/release helper scripts and for the npm MCP wrapper. Core Swift builds do not require Node. |

If a doc mentions platform support, prefer linking back here instead of restating a separate compatibility matrix.
