---
summary: 'Manual MCP smoke tests via mcporter for Peekaboo'
read_when:
  - 'verifying Peekaboo MCP server changes or regressions'
  - 'running hand-driven MCP smokes before releases'
---

# Manual MCP Testing (mcporter)

Use this checklist to exercise the Swift MCP server with mcporter. It mirrors the Oracle smokes but targets the Peekaboo CLI (`peekaboo mcp serve`) so we can validate stdio transport, tool schemas, and basic automation without relying on Codex, Claude Code, or Cursor.

## Quick setup
- Build the CLI: `pnpm run build:cli` (or `pnpm run build:swift` for release binaries).
- Export the binary path for reuse:  
  `export PEEKABOO_BIN="$(swift build --show-bin-path --package-path Apps/CLI)/peekaboo"`
- Pick a mcporter entry point (set once):  
  `export MCPORTER="${MCPORTER:-npx mcporter}"`  
  If you have the local repo, prefer `MCPORTER="pnpm --dir ~/Projects/mcporter exec tsx ~/Projects/mcporter/src/cli.ts"`.
- mcporter timeouts are **milliseconds**. Use `--timeout 15000` (15s), not `--timeout 15`.
- Permissions: run `$PEEKABOO_BIN permissions status` once to confirm Screen Recording + Accessibility are granted; the `permissions` tool fails when either required grant is missing and reports Event Synthesizing separately.
- AI analysis (optional steps below) needs providers set in `~/.peekaboo/config.json` and env keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.).

## Test cases (run in order)

1) **Discover + schema check**  
   ```
   $MCPORTER list --stdio "$PEEKABOO_BIN mcp serve" --name peekaboo-local --schema --timeout 30000
   ```  
   Expect: tool catalog prints Peekaboo-native tools (image, capture, see, list, permissions, click, type, drag, window, menu, dock, space, swipe, hotkey, clipboard, agent, sleep). Any transport/auth errors here block the rest of the suite.

2) **Permissions sanity**  
   ```
   $MCPORTER call --stdio "$PEEKABOO_BIN mcp serve" --name peekaboo-local permissions --timeout 15000
   ```  
   Expect Screen Recording ✅ (hard requirement) and Accessibility ⚠️/✅. If Screen Recording is missing, fix it before continuing.

3) **Server status via list tool**  
   ```
   $MCPORTER call --stdio "$PEEKABOO_BIN mcp serve" --name peekaboo-local \
     list item_type:server_status --timeout 20000
   ```  
   Expect version string (3.x), active provider names, and a healthy status line.

4) **Window inventory**  
   ```
   $MCPORTER call --stdio "$PEEKABOO_BIN mcp serve" --name peekaboo-local \
     list item_type:application_windows app:"Finder" \
     include_window_details:'["bounds","ids"]' --timeout 20000
   ```  
   Expect numbered windows with titles; bounds/IDs present when Finder has open windows. Swap `app:` to any running target if Finder is closed.

5) **Screenshot smoke (frontmost)**  
   ```
   $MCPORTER call --stdio "$PEEKABOO_BIN mcp serve" --name peekaboo-local \
     image path:/tmp/peekaboo-mcp/frontmost.png format:png \
     app_target:frontmost capture_focus:auto --timeout 25000
   ```  
   Expect `📸 Captured …` text plus a saved file path. Open the PNG to confirm the active window is captured without the shadow frame.

6) **Bounded live capture smoke**
   ```
   $MCPORTER call --stdio "$PEEKABOO_BIN mcp serve" --name peekaboo-local \
     capture source:live mode:area region:100,100,640,360 \
     duration_seconds:2 active_fps:4 threshold_percent:0 \
     output_dir:/tmp/peekaboo-mcp/live video_out:/tmp/peekaboo-mcp/live.mp4 \
     --timeout 45000
   ```
   Expect kept-frame text plus `contact.png`, `metadata.json`, one or more frame PNGs, and a non-empty MP4 when `video_out` is set.

7) **Image + analysis (optional, needs AI keys)**
   ```
   $MCPORTER call --stdio "$PEEKABOO_BIN mcp serve" --name peekaboo-local \
     image path:/tmp/peekaboo-mcp/frontmost-analysis.png format:png \
     app_target:frontmost capture_focus:auto \
     question:"What window is in focus?" --timeout 60000
   ```  
   Expect an analysis paragraph plus `savedFiles` metadata; failures here usually mean provider config or permissions issues.
   Note: OpenAI Responses (GPT‑5.x) requires `image_url` to be a string (URL or data URL). Peekaboo normalizes legacy `{ url, detail }` objects internally, but upstream tools should prefer the string form to avoid 400s.

8) **List cached tools after reuse (daemon/keep-alive sanity)**
   ```
   $MCPORTER list --stdio "$PEEKABOO_BIN mcp serve" --name peekaboo-local --timeout 15000
   ```  
   Expect a fast re-list with no lingering stderr; if it hangs, run `$MCPORTER daemon stop` and retry to rule out stuck keep-alive state.

## Notes
- These smokes use ad-hoc stdio (`--stdio "$PEEKABOO_BIN mcp serve"`), so no project config file is required. If you prefer persistence, add `--persist ~/.mcporter/mcporter.json --name peekaboo-local --yes` on the first `list` call.
- Record pass/fail plus notable log snippets or file paths in PR descriptions so reviewers can audit the real runs.
- If any step fails because the server stays busy, re-run with `DEBUG=mcp` to surface raw MCP traffic, then check for crash logs under `~/Library/Logs/DiagnosticReports/peekaboo*`.
