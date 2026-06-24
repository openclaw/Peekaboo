---
name: peekaboo
description: "Use Peekaboo for macOS desktop automation, screenshots, visual UI maps, native accessibility inspection, app/window/menu/dialog control, native app and browser chrome control, browser-page MCP tooling, MCP diagnostics, and Peekaboo repo validation. Use when Codex needs current macOS UI state, direct desktop control, privacy-aware live smoke tests, or changes to the Peekaboo repository."
---

# Peekaboo

Peekaboo is a macOS automation CLI and agent runtime. Prefer the freshly built repo binary, live help, and canonical docs over copied command references because command surfaces move quickly.

## Start Here

1. In repo work, build and use the current-source binary:
   ```bash
   pnpm run build:cli
   BIN="$(swift build --package-path Apps/CLI --show-bin-path)/peekaboo"
   "$BIN" --version
   ```
2. Record the installed PATH binary separately when diagnosing environment drift:
   ```bash
   command -v peekaboo && peekaboo --version
   ```
3. Confirm permissions and current tool surfaces before automation:
   ```bash
   "$BIN" permissions status --json
   "$BIN" tools --json
   "$BIN" learn
   ```
4. Find command docs:
   ```bash
   node scripts/docs-list.mjs
   ```

## Canonical References

- Live CLI help: `peekaboo <command> --help`
- Full agent guide: `peekaboo learn`
- Tool catalog: `peekaboo tools`
- Command docs in this repo: `docs/commands/README.md` and `docs/commands/*.md`
- Permissions and bridge behavior: `docs/permissions.md`, `docs/bridge-host.md`, `docs/integrations/subprocess.md`
- Repo rules: `AGENTS.md`

## Observation Strategy

- Use `peekaboo inspect-ui` (CLI) or `inspect_ui` (MCP) for native macOS AX text, labels, buttons, text fields, control state, and element IDs when a screenshot would add noise.
- Use `peekaboo see` for screenshots, visual layout, annotated maps, pixels, colors, screen/menu-bar targets, or cases where AX text is missing or incomplete.
- Use `browser` for browser page content, forms, DOM/a11y snapshots, console, network, page screenshots, and performance traces when browser tooling is available.
- Use native Peekaboo tools for app chrome, browser toolbars, menus, dialogs, permissions, windows, and non-browser apps.
- Treat element IDs from `see` or `inspect_ui` as valid only for the current visible state. After a mutating action, verify from the action result or fetch fresh state.

## Operating Rules

- Use `peekaboo see --json --path /tmp/<name>.png` or `peekaboo inspect-ui --json` before element interactions so you have fresh element IDs and snapshot IDs.
- Prefer the exact element ID string from the current snapshot for clicks and typing; treat ID shapes as opaque. Use labels when IDs are unavailable and coordinates only as a last resort.
- Check `peekaboo permissions status --json` before assuming a capture or control failure is a CLI bug.
- Use `--json` when another tool or agent needs to parse results.
- Respect the user's desktop: avoid destructive app/window actions unless requested.
- If a command fails because the target UI changed, recapture with `see` or `inspect-ui` before retrying.
- `see --json` element bounds are screen coordinates. Snapshot IDs keep element actions tied to the observed UI.
- When using `see` in agent smoke tests, pass an explicit `/tmp` `--path` so capture artifacts do not land in a user-visible default location.
- Prefer `--foreground` only when an app requires a key window, Space switch, or foreground mouse event. Background delivery is the default when Peekaboo can resolve a target process.

## Common Workflows

```bash
# AX-only state when a screenshot would add noise.
peekaboo inspect-ui --app-target Calculator --json > /tmp/peekaboo-calc-ax.json

# Visual layout plus element IDs and snapshot ID.
peekaboo see --app Calculator --path /tmp/calc.png --json > /tmp/calc.json
ruby -rjson -e 'j=JSON.parse(File.read("/tmp/calc.json")); puts j.dig("data","snapshot_id"); puts JSON.pretty_generate((j.dig("data","ui_elements")||[]).map{|e| e.slice("id","label","identifier","bounds")})'

# Click an element discovered in the current snapshot.
SNAP=$(ruby -rjson -e 'j=JSON.parse(File.read("/tmp/calc.json")); puts j.dig("data","snapshot_id")')
ELEMENT_ID="<element-id-from-current-snapshot>"
peekaboo click --on "$ELEMENT_ID" --snapshot "$SNAP" --json

# Browser page content and DOM-oriented actions belong to browser tooling.
peekaboo browser status --json

# Browser toolbar, menus, permission prompts, and native app chrome still belong to Peekaboo.
peekaboo menu list --app Safari --json
```

## Input Path Testing

Peekaboo has two broad input paths:

- UIAX/action path: accessibility actions such as `AXPress`, `AXSetValue`.
- Synthetic path: pointer/keyboard events, commonly the CAEvent/CGEvent-style path.

Useful overrides:

```bash
# Confirm command exposes the override.
peekaboo click --help | rg 'input-strategy|actionOnly|synthOnly'

# UIAX/action click path from a saved snapshot.
peekaboo see --app Calculator --path /tmp/calc.png --json > /tmp/calc.json
SNAP=$(ruby -rjson -e 'j=JSON.parse(File.read("/tmp/calc.json")); puts j.dig("data","snapshot_id")')
ELEMENT_ID="<element-id-from-current-snapshot>"
peekaboo click --on "$ELEMENT_ID" --snapshot "$SNAP" --input-strategy actionOnly --json --focus-background

# Direct accessibility action; good for proving UIAX independent of pointer events.
peekaboo perform-action --on "$ELEMENT_ID" --action AXPress --snapshot "$SNAP" --json

# Synthetic click path; allow focus if you need visible app state to mutate.
peekaboo click --on "$ELEMENT_ID" --snapshot "$SNAP" --input-strategy synthOnly --json --foreground

# Negative control: coordinates cannot use actionOnly.
peekaboo click --coords 10,10 --input-strategy actionOnly --json
```

Interpretation:

- `actionOnly` success proves live AX re-resolution and action invocation.
- `synthOnly` success proves coordinate resolution and event delivery, but verify app state independently.
- `perform-action AXPress` is the cleanest UIAX smoke test.
- Compare with Computer Use or another AX inspector when labels/descriptions differ.

## Calculator Smoke Test

Calculator is a handy fixture because it exposes descriptions and identifiers.

```bash
BIN="$(swift build --package-path Apps/CLI --show-bin-path)/peekaboo"
"$BIN" permissions status --json > /tmp/peekaboo-skill-refresh-permissions.json
"$BIN" tools --json > /tmp/peekaboo-skill-refresh-tools.json
"$BIN" inspect-ui --app-target Calculator --json > /tmp/peekaboo-skill-refresh-calc-ax.json
"$BIN" see --app Calculator --path /tmp/peekaboo-skill-refresh-calc.png --json --timeout-seconds 10 > /tmp/calc.json
ruby -rjson -e 'j=JSON.parse(File.read("/tmp/calc.json")); puts JSON.pretty_generate((j.dig("data","ui_elements")||[]).select{|e| ["Clear","AllClear","One","Two","Add","Equals","StandardInputView"].include?(e["identifier"].to_s)}.map{|e| e.slice("id","label","identifier","description","help","bounds")})'

SNAP=$(ruby -rjson -e 'j=JSON.parse(File.read("/tmp/calc.json")); puts j.dig("data","snapshot_id")')
BUTTON_ID="<button-id-from-current-snapshot>"
"$BIN" perform-action --on "$BUTTON_ID" --action AXPress --snapshot "$SNAP" --json
"$BIN" click --on "$BUTTON_ID" --snapshot "$SNAP" --input-strategy actionOnly --json --focus-background
```

Expected current behavior:

- `see --json` includes `bounds` for each `ui_elements` entry.
- `inspect-ui --json` and `see --json` should expose element IDs plus Calculator identifiers such as `One`, `Two`, and `StandardInputView`. Copy the returned ID exactly instead of assuming a prefix or shape.
- `tools --json` should include `browser`, `click`, `inspect_ui`, and `see`.
- Snapshot-backed UIAX must use the captured app/window, not the frontmost app.

## Repo Validation

```bash
node scripts/docs-lint.mjs
ruby -e 'h=File.read("skills/peekaboo/SKILL.md").split(/^---\s*$/,3)[1]; keys=h.lines.grep(/^[A-Za-z0-9_-]+:/).map { |line| line.split(":",2).first }; abort("frontmatter keys: #{keys.inspect}") unless keys.sort == ["description","name"]'
! rg -n 'elem_[0-9]+' skills/peekaboo/SKILL.md
! rg -n '^allowed-tools:' skills/peekaboo/SKILL.md
pnpm run build:cli
BIN="$(swift build --package-path Apps/CLI --show-bin-path)/peekaboo"; "$BIN" --version
"$BIN" click --help | rg -- '--foreground|--focus-background|--input-strategy|Opaque element ID'
"$BIN" see --help | rg -- '--json|--annotate|--app|--no-web-focus'
"$BIN" inspect-ui --help | rg 'inspect_ui|--app-target|--snapshot|--json'
git diff --check -- skills/peekaboo/SKILL.md docs/agent-skill.md docs/commands/see.md docs/automation.md scripts/docs-lint.mjs
```

Notes:

- If tests fail with `no such module 'Testing'`, record it as local toolchain fallout; still run builds/lint/live smoke tests.
- SwiftPM may warn about Commander identity conflicts; do not chase unless the task is dependency hygiene.
- Keep live validation artifacts under `/tmp/peekaboo-skill-refresh-*` and do not commit or publish screenshots or UI dumps.

Keep this skill compact. Do not vendor generated command references here; update canonical CLI docs or Commander metadata instead.
