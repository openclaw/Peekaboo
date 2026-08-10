---
summary: 'Manual Trimmy test plan using peekaboo clipboard'
read_when:
  - 'verifying Trimmy clipboard trimming behavior'
  - 'running manual clipboard regression tests'
---

# Trimmy Manual Test Plan (with Peekaboo clipboard tool)

Goal: Validate Trimmy’s clipboard flattening with direct `peekaboo clipboard` invocations.

## Prereqs
- Peekaboo CLI built at `Apps/CLI/.build/release/peekaboo`.
- Trimmy running with Accessibility permission.
- Peekaboo granted Screen Recording + Accessibility.
- Target app for paste checks: TextEdit.
- Locate Trimmy menubar index: `peekaboo menubar list --json-output | jq '.items[] | select(.title|contains("Trimmy")) | .index'`

## Manual Steps
1) Auto-Trim ON (baseline)  
   - `peekaboo clipboard set --text "ls \\\n | wc -l\n"`
   - Wait ~0.3s; `peekaboo clipboard get` → expect `ls | wc -l`.

2) Auto-Trim OFF path  
   - `peekaboo menubar click --index <idx> --foreground` → `peekaboo click "Auto-Trim"` (toggle off).
   - Reseat text as above; wait; `get` should stay multi-line.  
   - Toggle Auto-Trim back on.

3) Aggressiveness Low vs High  
   - Open Settings → Aggressiveness tab: menubar click → “Settings…” → “Aggressiveness”.  
   - Low: `peekaboo click "Low (safer)"`; seed `echo "hi"\nprint status\n`; expect unchanged.  
   - High: `peekaboo click "High (more eager)"`; reseed; expect single-line `echo "hi" print status`.

4) Box-drawing stripping  
   - Ensure “Remove box drawing chars” enabled (General tab).  
   - Seed `│ ls -la \\\n│ | grep foo\n`; expect `ls -la | grep foo`.

5) Keep blank lines  
   - Enable “Keep blank lines”.  
   - Seed `echo one\n\necho two\n`; expect blank line preserved.

6) Prompt stripping  
   - Seed `$ brew install foo\n$ brew update\n`; expect `brew install foo brew update`.

7) Safety valve (>10 lines)  
   - Seed 12-line blob (e.g., `yes line | head -n 12 | paste -sd '\n'` piping into clipboard set).  
   - Expect no flattening.

8) Paste Trimmed vs Original  
   - Frontmost TextEdit: `open -a TextEdit`.  
   - Seed multi-line command.  
   - Menubar click → “Paste Trimmed to TextEdit”; verify with `peekaboo see --app TextEdit --tree --no-screenshot --json` and inspect the native AX text value.
   - Menubar click → “Paste Original …”; verify the untrimmed AX text value the same way and confirm the clipboard was restored (`peekaboo clipboard get` matches the original).

9) Clipboard slots  
   - `peekaboo clipboard save --slot original`
   - `peekaboo clipboard set --text "temp"`
   - `peekaboo clipboard restore --slot original`; `get` should match saved content.

## Debug Log Template
Append per-run notes here:
```
[YYYY-MM-DD HH:MM] Step: <name>
Commands:
  peekaboo clipboard set --text "..."
Observed:
  clipboard get -> "<value>"
  UI state: Auto-Trim <on/off>, Aggressiveness <Low/Normal/High>
Result: PASS/FAIL
Notes: <details>
```

### Latest menubar scan (2025-11-22)
- Built CLI: `Apps/CLI/.build/release/peekaboo` (includes raw-debug flag + CGS bridges).
- Command: `peekaboo menubar list --json-output --include-raw-debug --log-level debug`.
- Output (post-filtering): 23 items. Trimmy now appears once (title “Trimmy”, source `ax-app`, raw_title “Cut”), CGS items remain Control Center/Notification Center only.
- Implication: We surfaced Trimmy via AX status sweep, but CGS still can’t see it. Need to improve title fidelity (use identifier/help) and confirm we’re not just picking a menu child. Continue hit-test/AX correlation.
