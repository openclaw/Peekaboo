---
summary: 'Install and maintain the thin Peekaboo CLI agent skill.'
read_when:
  - 'setting up Peekaboo with AI agents'
  - 'updating the peekaboo skill'
---

# Agent Skill for Peekaboo

The `peekaboo` skill teaches agents when and how to use Peekaboo for macOS automation, screenshots, native accessibility inspection, native app and browser chrome, browser-page tooling, and repo validation. It intentionally stays thin: agents should use live CLI help, `peekaboo learn`, `peekaboo tools`, and canonical docs instead of a copied command reference that can drift.

## Install

Copy the skill directory into your agent's skills folder:

```bash
# Claude Code
mkdir -p ~/.claude/skills
cp -r skills/peekaboo ~/.claude/skills/

# OpenClaw
mkdir -p ~/.openclaw/skills
cp -r skills/peekaboo ~/.openclaw/skills/
```

Restart the agent after installing or updating the skill.

## Prerequisites

Install Peekaboo and grant macOS permissions:

```bash
brew install steipete/tap/peekaboo
peekaboo permissions status
peekaboo permissions grant
```

Agents should also use `peekaboo learn`, `peekaboo tools`, and `peekaboo <command> --help` for the current command surface.

## Canonical Docs

- Skill file: `skills/peekaboo/SKILL.md`
- Command index: `docs/commands/README.md`
- Command pages: `docs/commands/*.md`
- Permissions: `docs/permissions.md`
- Subprocess/OpenClaw integration: `docs/integrations/subprocess.md`

## Maintenance Rule

Keep the skill compact and progressive. Its frontmatter should contain only `name` and `description`, and its body should explain observation strategy and validation flow without vendoring generated command catalogs. Update Commander metadata, `peekaboo learn`, or `docs/commands/*` when command behavior changes.
