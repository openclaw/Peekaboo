## [3.10.0] - 2026-08-02

### Added
- Add reference-bound image-pixel and normalized MCP click coordinates, building on capture context from @scotthuang in #310.

### Fixed
- Honor cancellation promptly and deterministically in daemon polling and CLI timeout helpers. Thanks @SebTardif for #311.
- Avoid a Swift 6.3 release-compiler crash by reusing the shared timeout race for provider commands.

### Changed
- Update Sparkle to 2.9.5, swift-log to 1.15.0, swift-system to 1.8.0, Swiftdansi to 0.3.0 development, and Tachikoma to current main.
