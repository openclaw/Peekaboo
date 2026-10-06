---
summary: 'Work with macOS status items via peekaboo menubar'
read_when:
  - 'clicking Wi-Fi/Bluetooth/battery icons from automation flows'
  - 'enumerating third-party status items with indices for later use'
---

# `peekaboo menubar`

`menubar` is a lightweight helper for macOS status items (a.k.a. menu bar extras). It talks directly to `MenuServiceBridge` so you can list every icon with its index or click one by title/index. Listing is read-only and stays in the background. Clicking opens global menu bar UI and therefore requires explicit `--foreground` consent. Use the `menu` command for traditional application menus; this command is strictly for the right-hand side of the menu bar.

## Subcommands
| Subcommand | Description |
| --- | --- |
| `list` | Prints every visible status item with its index. `--json` emits the same data plus bundle IDs and AX identifiers. |
| `click` | Clicks a displayed item by name or index, or an application-owned item by name with `--app`/`--pid`. |

## Key options
| Flag | Description |
| --- | --- |
| `[itemName]` | Optional positional argument passed to `click`. |
| `--index <n>` | Target by numeric index (matches the ordering from `menubar list`). |
| `--app <name-or-bundle-id>` | For named `click` only: inspect AX extras in one exact application. Mutually exclusive with `--pid` and `--index`. |
| `--pid <pid>` | For named `click` only: inspect AX extras in one exact positive PID. Mutually exclusive with `--app` and `--index`. |
| `--foreground` | Required for `click`; permits Peekaboo to open global status-item UI and interrupt the current foreground workflow. |
| `--verify` | After clicking, confirm a popover owned by the same PID appears, or that focus moved to the owning app/window (fallback OCR). OCR requires the popover text to include the target title/owner name and anchors verification to the clicked item’s X position when available. |
| Global flags | `--json` returns structured payloads; `--verbose` adds descriptions when listing. |

## Implementation notes
- The command name is `menubar` (no hyphen). `list` and `click` are real Commander subcommands.
- Listing uses `MenuServiceBridge.listMenuBarItems`, and verbose mode prints extra diagnostics (owner name, hidden state). JSON mode always includes the raw title, bundle ID, owner name, identifier, visibility, and description.
- `click` refuses before status-item lookup unless `--foreground` is present. Missing names and stale indices then fail before dispatch as `MENU_ITEM_NOT_FOUND` with `effect: refused`, `retry_safe: true`, and `mutation_dispatched: false` in JSON.
- Clicking resolves either `--index` or item text (case-insensitive). Name-based targets remain name-based at dispatch so a status-item reorder cannot redirect the click to a different index.
- Unscoped names and indices retain the displayed WindowServer inventory and exact window route. A unique displayed name does not trigger a global AX sweep; unrelated graphics helpers cannot block that route. Ambiguous or stale displayed evidence still refuses before dispatch.
- `click <name> --app ...` or `--pid ...` prepares a deadline-bounded `AXExtrasMenuBar` inventory only inside that exact application generation. It retains the original owner selector and native leaf through dispatch, without borrowing a Control Center proxy's window ID. Preparation never focuses the app. Missing, unreadable, changed or ambiguous targets refuse; an uncertain AX submission is never retried through another route.
- Within an explicit owner, item text matches only the native leaf's title, help, description or identifier. The application name and bundle ID are owner selectors, not additional item-name aliases.
- Scoped clicks require explicit `--foreground` just like unscoped clicks, and cannot use `--index`. They never fall back to another application or the global inventory. Bridge hosts and clients must negotiate `scopedMenuBarActions`, the scoped preparation operation and attested receipts; older hosts refuse rather than ignore the owner scope.
- Existing programmatic `clickMenuExtra` APIs retain their Accessibility-only system-menu path without requiring a CG window or Event Synthesizing permission. Raw named SDK calls retain AX-first lookup with the existing safe pre-dispatch fallback. Neither compatibility route replaces the evidence-bound request used by the CLI and current attested remote named calls.
- `--verify` waits briefly for a popover owned by the same PID, checks for a focused-window change for the owning app, then falls back to any visible owner window (layer 0). OCR verification is on by default (set `PEEKABOO_MENUBAR_OCR_VERIFY=0` to disable) and now requires the popover text to include the target title/owner; AX menu checks remain opt-in via `PEEKABOO_MENUBAR_AX_VERIFY=1` (OCR requires Screen Recording permission).
- Coordinate data (if available) is recorded in the click result so you can correlate where on screen the interaction happened.

## Examples
```bash
# List every status item with indices
peekaboo menubar list

# Click the Wi-Fi icon by name
peekaboo menubar click "Wi-Fi" --foreground

# Click and verify the popover opened
peekaboo menubar click "Wi-Fi" --verify --foreground

# Click the third item regardless of name and capture JSON output
peekaboo menubar click --index 3 --foreground --json

# Address a third-party app's AX-owned status item explicitly
peekaboo menubar click "Status Item" --app com.example.StatusApp --foreground --json

# Bind the named item to a PID obtained from app list
peekaboo menubar click "Status Item" --pid 12345 --foreground --json
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
