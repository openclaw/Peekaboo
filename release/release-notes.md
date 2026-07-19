## [3.9.6] - 2026-07-19

### Highlights
- Peekaboo 3.9.6 completes the signing migration: the app, CLI, nested helpers, zip payload, and DMG now use the OpenClaw Foundation Developer ID. macOS treats the changed CLI signer as a new TCC identity, so re-grant Screen Recording, Accessibility, and any Automation access you use after updating.

### Changed
- Sign and notarize every shipped macOS code object with `Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)` while preserving bundle identifiers and the existing Sparkle EdDSA update key; 3.8+ bridge hosts continue accepting transition-era personal-team clients, while the 3.9.6 CLI requires a 3.8+ host.

### Fixed
- Reopen permission onboarding once for users whose required grants are missing after the signing migration, with direct guidance to re-grant Screen Recording, Accessibility, and Automation access.
