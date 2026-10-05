---
summary: 'Peekaboo documentation map'
read_when:
  - 'finding the right Peekaboo doc quickly'
  - 'onboarding or sharing docs with teammates'
---

# Documentation map

- **Commands** — `commands/README.md` plus one page per CLI command.
- **Providers** — `providers.md` for the central provider list; `providers/README.md` for deep links.
- **Architecture & specs** — `ARCHITECTURE.md` and `spec.md`.
- **Testing & QA** — `testing/` plans and manual guides, `reports/` results.
- **References** — `references/` for external API reference excerpts (e.g., Swift toolchain/testing).
- **Research & design notes** — `research/` deep dives and spike notes.
- **Refactors** — `refactor.md` points to the active plan; older migration logs live in `archive/refactor/`.
- **Release & ops** — `platform-support.md`, `RELEASING.md`, `building.md`, `permissions.md`, `security.md`.

Use `pnpm run docs:list` for a searchable summary of all docs.

The listing reads JSON inline `read_when` arrays without rewriting apostrophes or escaped characters, and retains the existing simple single-quoted-array fallback. It is not a general YAML parser. Checked-in documentation should continue using block-list `read_when` entries as required by the separate docs linter; this listing compatibility does not change that lint contract.
