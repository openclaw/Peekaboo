---
summary: 'Review Window Focus and Space Management guidance'
read_when:
  - 'planning work related to window focus and space management'
  - 'debugging or extending features described here'
---

# Window Focus and Space Management

Peekaboo provides intelligent window focusing that works seamlessly across macOS Spaces (virtual desktops), ensuring your automation commands always target the correct window.

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Automatic Focus Management](#automatic-focus-management)
- [Focus Options](#focus-options)
- [Window Focus Command](#window-focus-command)
- [Space Management](#space-management)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)
- [Technical Details](#technical-details)

## Overview

Starting with v3, Peekaboo includes comprehensive window focus management that:

- **Tracks window identity** across interactions using stable window IDs
- **Detects window location** across different Spaces
- **Switches Spaces only with explicit foreground consent**
- **Ensures window focus** before foreground interaction
- **Handles edge cases** like minimized windows, closed windows, and multi-display setups

This eliminates the need for manual window management in your automation scripts.

## How It Works

### Window Identity Tracking

Peekaboo uses multiple methods to track windows:

1. **CGWindowID** - A stable identifier that persists for the window's lifetime
2. **AXIdentifier** - Optional developer-provided stable ID (rarely available)
3. **Window Title** - Human-readable but can change
4. **Window Index** - Position-based, least stable

When you use the `see` command, Peekaboo stores the window's CGWindowID in the snapshot, allowing subsequent commands to reliably target the same window even if its title changes or it moves between Spaces.

### Focus Flow

When you execute a foreground interaction command (`type`, `click --foreground`, etc.), Peekaboo:

1. **Retrieves window info** from the current snapshot
2. **Checks if window still exists** (handles closed windows gracefully)
3. **Detects which Space** contains the window
4. **Switches or moves Spaces** only when `--space-switch` or `--bring-to-current-space` is explicit
5. **Brings app to front** and focuses the specific window
6. **Verifies focus succeeded** before proceeding
7. **Executes your command** on the correctly focused window

## Automatic Focus Management

Foreground interaction commands automatically handle focus:

```bash
# These commands all include automatic focus management:
peekaboo click "Submit" --app Safari --foreground
peekaboo type "Hello world" --app TextEdit --foreground
peekaboo scroll --direction down --foreground
peekaboo menu click --app Safari --item "New Tab" --foreground
peekaboo press cmd+s --app TextEdit --foreground
peekaboo drag --from "$SOURCE_ID" --to "$TARGET_ID" --foreground
```

### Default Behavior

By default, Peekaboo will:
- ✅ Keep targeted interaction in the background when the command supports it
- ✅ Focus the target window only after explicit foreground consent
- ✅ Refuse an unintended Space switch unless `--space-switch` or `--bring-to-current-space` is explicit
- ✅ Wait up to 5 seconds for focus to complete
- ✅ Retry up to 3 times if focus fails
- ✅ Verify focus before proceeding

## Focus Options

Interaction commands that use foreground delivery support these focus-related options. `click`, `type`, and `paste`
default to background delivery when Peekaboo can resolve a target process. Raw `press` stays background only with a
fresh exact-window/snapshot receipt; app/PID-only and targetless forms require `--foreground`. Targeted scroll stays
background through Accessibility or a capability-gated exact-window WebKit route, while targetless/smooth scroll and
all move/drag operations require explicit foreground mode.

### `--no-auto-focus`
Disables automatic focus management (not recommended).

```bash
peekaboo click "Submit" --foreground --no-auto-focus
```

Use cases:
- When you've already manually focused the window
- For coordinate-based clicks that don't need window focus
- Testing or debugging focus issues

### `--focus-background`
Uses command-supported background delivery instead of activating the target app. For input commands that can resolve a
target process, this is now the default; the flag is a legacy alias where still exposed. `press` retains the spelling
for compatibility, but the alias does not replace the fresh exact-window/snapshot receipt required for background raw
chords.

```bash
peekaboo press cmd+l --app Safari --foreground
peekaboo window list --app Safari --json
peekaboo see --window-id "$WINDOW_ID" --no-elements --json
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at 420,180
peekaboo type "hello" --app TextEdit
```

Use cases:
- Clicking app-local coordinates without activating the target app
- Typing or pasting into a targeted app without activating it
- Keeping a long-running foreground workflow uninterrupted

Currently, typed text and paste use background delivery when `--app`, `--pid`, or supported snapshot process metadata
identifies a live process. Raw key chords require either a fresh exact-window/snapshot focused-element receipt or
explicit `--foreground`; app/PID-only and targetless raw chords refuse. Background click can preserve an exact
window/element target.

Background delivery is a delivery mode, not a focus mode. It cannot be combined with foreground focus timeout, retry, or Space-switching flags. Background element/query/coordinate clicks and targeted scroll prefer Accessibility; an opaque WebKit scroll target may use exact PID/window wheel delivery without focus. Keyboard delivery, that WebKit wheel route, and foreground synthetic pointer operations require Event Synthesizing; `peekaboo permissions request event-synthesizing` requests it for the selected bridge host by default, or for the local CLI with `--no-remote`.

### `--focus-timeout <duration>`
Sets how long to wait for focus operations (default: `5s`; bare values are milliseconds).

```bash
peekaboo type "Long text..." --app TextEdit --foreground --focus-timeout 10s
```

Use cases:
- Slow-loading applications
- Heavy system load
- Network-based apps that may be sluggish

### `--focus-retry-count <number>`
Sets how many times to retry focus operations (default: 3).

```bash
peekaboo click "Save" --foreground --focus-retry-count 5
```

Use cases:
- Unreliable applications
- System under heavy load
- Critical operations that must succeed

### `--space-switch`
Forces Space switching even if window appears to be on current Space.

```bash
peekaboo click "Login" --foreground --space-switch
```

Use cases:
- When macOS Space detection is unreliable
- Ensuring you're on the correct Space
- Debugging Space-related issues

### `--bring-to-current-space`
Moves the window to your current Space instead of switching to it.

```bash
peekaboo type "Hello" --foreground --bring-to-current-space
```

Use cases:
- Keeping your current workspace
- Consolidating windows from multiple Spaces
- Avoiding Space switch animations

## Window Focus Command

For explicit window management, use the `window focus` command:

```bash
# Basic usage on the current Space
peekaboo window focus --app Safari

# Focus specific window by title
peekaboo window focus --app Chrome --window-title "Gmail"

# Switch to the target window's Space
peekaboo window focus --app Terminal --space-switch

# Move window to current Space
peekaboo window focus --app TextEdit --bring-to-current-space

# Request an explicit post-focus verification
peekaboo window focus --app Finder --verify
```

### Options

- `--app <name>` - Application name, bundle ID, or PID
- `--window-title <title>` - Specific window title (partial match)
- `--window-index <number>` - Window index (0-based)
- `--space-switch` - Switch to the target window's Space
- `--bring-to-current-space` - Move the target window to the current Space
- `--verify` - Verify the exact window is focused after the action

## Space Management

Peekaboo provides comprehensive Space (virtual desktop) management:

### List Spaces

```bash
# List all user Spaces
peekaboo space list

# Include detailed window assignments
peekaboo space list --detailed

# JSON output
peekaboo space list --json
```

The list marks the active Space for each display; add `--json` when a script needs the active ID.

### Switch Spaces

```bash
# Switch to Space 2 (1-based numbering)
peekaboo space switch --to 2 --foreground

```

### Move Windows Between Spaces

```bash
# Move Safari to Space 3
peekaboo space move-window --app Safari --to 3

# Move specific window
peekaboo space move-window --app Chrome --window-title "Gmail" --to 2
```

### Find Windows

```bash
# Include each Space's windows, then match the app or title in the result
peekaboo space list --detailed --json
```

## Best Practices

### 1. Use Sessions

Always start with `see` to establish a snapshot:

```bash
# Good: Establish an exact-window snapshot before acting
peekaboo window list --app Safari --json
peekaboo see --window-id "$WINDOW_ID" --json
peekaboo click "Login" --foreground
peekaboo type "username" --app Safari
```

### 2. Let Peekaboo Handle Focus

Don't manually manage windows:

```bash
# Don't do this:
peekaboo window focus --app Safari
peekaboo click "Submit"

# Do this instead (automatic focus):
peekaboo click "Submit" --foreground
```

### 3. Handle Space Switches Gracefully

Be aware that Space switching takes time:

```bash
# For critical operations, increase timeout
peekaboo click "Save" --foreground --focus-timeout 10s

# Or move windows to avoid switching
peekaboo type "Important data" --app TextEdit --foreground --bring-to-current-space
```

### 4. Test Cross-Space Workflows

Test your automation across different Space configurations:

```bash
# Test with window on different Space
peekaboo space move-window --app YourApp --to 2
peekaboo see --app YourApp  # Read-only observation does not switch Spaces
peekaboo click "Test Button" --app YourApp --foreground --space-switch
```

## Troubleshooting

### "Window in different Space" Error

This occurs when Space switching is disabled:

```bash
# Solution 1: Explicitly allow Space switching
peekaboo click "Button" --app YourApp --foreground --space-switch

# Solution 2: Move window to current Space
peekaboo click "Button" --app YourApp --foreground --bring-to-current-space

# Solution 3: Manually switch first
peekaboo space switch --to 2 --foreground
peekaboo click "Button" --app YourApp --foreground
```

### "Window not found" Error

The window may have been closed or minimized:

```bash
# Check if window still exists
peekaboo window list --app YourApp

# For minimized windows, restore first
peekaboo window restore --app YourApp
peekaboo click "Button" --app YourApp --foreground
```

### "Focus timeout" Error

The window is taking too long to focus:

```bash
# Increase timeout
peekaboo click "Button" --app YourApp --foreground --focus-timeout 10s

# Or increase retry count
peekaboo click "Button" --app YourApp --foreground --focus-retry-count 5
```

### Focus Not Working

If automatic focus isn't working:

```bash
# Debug with explicit focus
peekaboo window focus --app YourApp --verbose

# Check permissions
peekaboo permissions status

# Try without focus (for testing)
peekaboo click "Button" --app YourApp --foreground --no-auto-focus
```

## Implementation notes (internal)
- Window identity prefers `CGWindowID`, with `AXIdentifier`/title/index as fallbacks; sessions persist the ID for follow-up commands.
- Space management uses CGS APIs (`CGSCopySpaces`, `CGSManagedDisplaySetCurrentSpace`, add/remove windows to spaces) via `SpaceUtilities`.
- Focus pipeline: resolve window → ensure it exists → detect space → switch or move → bring app frontmost → focus window → verify → run command. Flags map to helpers (`--space-switch`, `--bring-to-current-space`, `--verify`, retries/timeouts).
- Tests live in CLI/Core; keep them in sync when changing SpaceUtilities or focus options.

## Technical Details

### Implementation

Focus management is implemented using:

- **CGWindowID** - Core Graphics window identifiers
- **CGSSpace APIs** - Private APIs for Space management
- **AXUIElement** - Accessibility APIs for window focus
- **NSWorkspace** - AppKit APIs for application activation

### Performance

- Focus operations typically complete in 50-200ms
- Space switching adds 200-500ms (animation time)
- Window ID lookup is O(1) when available
- Fallback to title search is O(n) where n = number of windows

### Limitations

1. **Multiple Displays** - Currently optimized for single display setups
2. **Full Screen Apps** - May have limited Space mobility
3. **Stage Manager** - Experimental support, may have edge cases
4. **Minimized Windows** - Cannot be focused directly (must restore first)

### Snapshot Storage

Window information stored in snapshots:

```json
{
  "windowID": 12345,
  "windowAXIdentifier": null,
  "bundleIdentifier": "com.apple.Safari",
  "applicationName": "Safari",
  "windowTitle": "Apple",
  "lastFocusTime": "2025-01-28T10:30:00Z"
}
```

This allows commands to quickly locate and focus the correct window without searching.

## See Also

- [Automation guide](automation.md)
- [Space Command Reference](commands/space.md)
- [Window Command Reference](commands/window.md)
- [Permissions](permissions.md)
