# Repository Guidelines

## Start Here
- Read `~/Projects/agent-scripts/{AGENTS.MD,TOOLS.MD}` before making changes (skip if missing).
- This repo uses git submodules (`AXorcist/`, `Commander/`, `Tachikoma/`, `TauTUI/`); update them in their home repos first, then bump pointers here.

## Project Structure & Modules
- `Apps/CLI` contains the SwiftPM package for the command-line tool; commands live under `Apps/CLI/Sources`, and unit/integration tests under `Apps/CLI/Tests`.
- `Apps/Mac`, `Apps/peekaboo`, and `Apps/PeekabooInspector` host the macOS app and related tooling; open `Apps/Peekaboo.xcworkspace` for Xcode work.
- Shared logic sits in `Core/PeekabooCore` (automation, agent runtime, visualizer). Keep new utilities there rather than duplicating in apps.
- Git submodules provide foundational pieces: `AXorcist/` (AX automation), `Commander/` (CLI parsing), `Tachikoma/` (AI providers/MCP), and `TauTUI/`. Update them upstream first, then bump the pointers here.
- Documentation lives in `docs/`; assets and marketing material are in `assets/`.

## Build, Test, and Development Commands
- Current local baseline is macOS 26.1 on arm64. If you’re on an older SDK/OS, expect menubar/accessibility flakiness; re-run with the 26 SDK before chasing Peekaboo regressions.
- Run tools directly (runner removed). Use pnpm (Corepack-enabled).
- Build the CLI: `pnpm run build:cli` (debug) or `pnpm run build:swift:all` (universal release). For arm64-only: `pnpm run build:swift`.
- Rebuild the Mac app while editing Swift: `./scripts/build-mac-debug.sh`.
- Validate before handoff: `pnpm run lint` (SwiftLint), `pnpm run format` (SwiftFormat check/fix), then `pnpm run test:safe`. Full automation/UI tests: `pnpm run test:automation` or `pnpm run test:all`.
- Tachikoma live provider checks: `pnpm run tachikoma:test:integration`.
- You may run `peekaboo` CLI commands locally for repros/debugging; be mindful they capture the host desktop (screen recording/accessibility permissions required).

## Coding Style & Naming Conventions
- Swift 6.2, 4-space indent, 120-column wrap; explicit `self` is required (SwiftFormat enforces). Run `pnpm run format` before committing.
- SwiftLint config lives in `.swiftlint.yml`; keep new code typed (avoid `Any`), prefer small scoped extensions over large files.
- Follow existing module boundaries: automation APIs in `PeekabooAutomation`, agent glue in `PeekabooAgentRuntime`, UI feedback in `PeekabooVisualizer`.

## Testing Guidelines
- Add regression tests alongside fixes in `Apps/CLI/Tests` (XCTest naming: `ThingTests`). Use `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` env only when automation permissions are available.
- For local end-to-end runs, ensure macOS Screen Recording and Accessibility are granted (`peekaboo permissions status|grant`).

## Commit & Pull Request Guidelines
- Conventional Commits (`feat|fix|chore|docs|test|refactor|build|ci|style|perf`); scope optional: `feat(cli): add capture retry`.
- Use `./scripts/committer "type(scope): summary" <paths…>` to stage and create commits; avoid raw `git add`.
- Batch git network ops in groups: commit related repo changes first, then push/pull repos together so submodule gitlinks stay coherent.
- PRs should summarize intent, list test commands executed, mention doc updates, and include screenshots or terminal snippets when behavior changes.
- Never release or publish without an explicit release command.
- Peekaboo releases: follow `$release-peekaboo`; current Mac + existing 1Password credentials first. App Store Connect changes last resort, only after same-item `notarytool history` and non-S3 `submit` both fail.
- Credentialed release wrappers: `bash -c`, never login shells; profile exports can override ASC IDs and mix credentials.
- Published CLI proof: run `npm exec` from `/tmp`; repo cwd may shadow the downloaded package with a local binary.
- During PR triage, keep moving autonomously: fix defects, add obvious scoped features, and rewrite or land what makes sense.
- Before landing every PR, run autoreview until no actionable findings remain and fix or rerun CI until green.

## Security & Configuration Tips
- Secrets and provider tokens live under `~/.peekaboo` (managed by Tachikoma); never commit credentials or sample keys.
- Respect permissions flows documented in `docs/permissions.md`; avoid editing derived artifacts—regenerate via the provided scripts instead.
