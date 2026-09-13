---
summary: 'Install and maintain the canonical Peekaboo agent skill.'
read_when:
  - 'setting up Peekaboo with AI agents'
  - 'updating or distributing the peekaboo skill'
---

# Agent Skill for Peekaboo

The [Peekaboo skill](../skills/peekaboo/SKILL.md) teaches agents to observe macOS UI, select an exact target, act in the background where supported, and verify the result. It covers native apps and browser chrome, routes page content to browser tooling, and explains execution-host permissions, snapshot ownership, coordinates, and unverified input outcomes. Ordinary automation uses the installed CLI; source builds belong to Peekaboo development.

## Prerequisites

Install the signed CLI and check permissions on the execution host:

```bash
brew install openclaw/tap/peekaboo
peekaboo --version
peekaboo bridge status --verbose --json
peekaboo permissions status --all-sources --json
```

See the [installation guide](install.md) for the GUI app and release archives. The CLI and app are separate executables; keep archive-supplied compatibility libraries with the CLI. Current matching releases reduce capability drift, while the actual Bridge contract is negotiated by protocol and operation capability. Grant permissions to the host performing the operation, not merely to the calling terminal. The skill includes an explicit GUI-socket recipe when app-held grants are needed.

## Install from a maintained checkout

Run from the Peekaboo repository root. Link the canonical directory into the agent's skill folder so updating this checkout updates its guidance:

```bash
PEEKABOO_REPO="$(pwd -P)"

# Codex
mkdir -p ~/.codex/skills
ln -s "$PEEKABOO_REPO/skills/peekaboo" ~/.codex/skills/peekaboo

# Claude Code
mkdir -p ~/.claude/skills
ln -s "$PEEKABOO_REPO/skills/peekaboo" ~/.claude/skills/peekaboo

# OpenClaw
mkdir -p ~/.openclaw/skills
ln -s "$PEEKABOO_REPO/skills/peekaboo" ~/.openclaw/skills/peekaboo
```

Use only the entry for the agent being configured. If that destination already exists, inspect and preserve local content before replacing it; do not nest a new link inside an existing directory. Verify the installed `peekaboo/SKILL.md` resolves to this checkout. The skill uses canonical web links for references, so documentation links remain useful through symlinks in another repository or agent directory. Start a new agent session after installing or updating, according to the host agent's skill-loading behavior.

## Distribution ownership

`skills/peekaboo/SKILL.md` in this repository is the canonical owner of Peekaboo command behavior and automation workflow guidance. A managed instruction repository can link to a sibling Peekaboo checkout instead of maintaining a second copy; its sync must update and verify the target checkout before exposing the link. Preserve host-specific binary paths, permission policy, and deployment details in the distributor's overlay, without duplicating product behavior.

Distributors that must work without a Peekaboo source checkout may copy a release-pinned snapshot. That copy is a distribution artifact: record its source release or commit, refresh it with Peekaboo releases, and send behavioral corrections upstream. A frozen snapshot must not be presented as live current-source guidance.

## Maintenance and validation

Keep frontmatter limited to `name` and `description`. Maintain a compact operational workflow rather than generated command catalogs or a mandatory build recipe. Check material claims against production source as well as live CLI help; copied help and older docs can themselves drift. Keep `peekaboo learn`, Commander metadata, and command documentation aligned when changing product behavior.

For skill/documentation edits, run from the repository root:

```bash
node scripts/docs-lint.mjs
ruby -e 'h=File.read("skills/peekaboo/SKILL.md").split(/^---\s*$/,3)[1]; keys=h.lines.grep(/^[A-Za-z0-9_-]+:/).map { |line| line.split(":",2).first }; abort("unexpected skill frontmatter") unless keys.sort == ["description","name"]'
git diff --check
```

Source-code changes follow [AGENTS.md](../AGENTS.md) and the [building guide](building.md). Live checks should use a controlled target, inspect the actual screen or state readback, and preserve retry-unsafe outcomes. Image dimensions and command success alone are insufficient proof that the intended UI changed.

## Canonical references

- [Command index](commands/README.md)
- [Permissions](permissions.md) and [Bridge hosts](bridge-host.md)
- [Subprocess integration](integrations/subprocess.md)
- `peekaboo <command> --help`, `peekaboo learn`, and `peekaboo tools describe <name> --json`
