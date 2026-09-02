---
summary: 'Review Application Resolution in Peekaboo guidance'
read_when:
  - 'planning work related to application resolution in peekaboo'
  - 'debugging or extending features described here'
---

# Application Resolution in Peekaboo

This document explains how Peekaboo resolves applications across commands that accept an application parameter.

## Overview

Peekaboo supports multiple ways to identify and target applications:
- **Application Name** - Human-readable name (e.g., "Safari", "Google Chrome")
- **Bundle ID** - Unique application identifier (e.g., "com.apple.Safari")
- **Process ID (PID)** - Numeric process identifier
- **Fuzzy Matching** - Partial name matching for convenience

## Command Line Parameters

Most commands that work with applications support two parameters:
- `--app` - Application name, bundle ID, or PID in format "PID:12345"
- `--pid` - Direct process ID as a number

### Examples

```bash
# By application name
peekaboo see --no-elements --app Safari

# By bundle ID
peekaboo window close --app com.apple.Safari

# By PID using --app parameter
peekaboo menu list --app "PID:12345"

# By PID using --pid parameter
peekaboo app quit --pid 12345

# Both parameters on a legacy window command (when they refer to the same app)
peekaboo window focus --app Safari --pid 12345
```

## Resolution Methods

### 1. Application Name

The most common method - uses the localized application name:

```bash
peekaboo see --no-elements --app "Google Chrome"
peekaboo window list --app TextEdit
```

**Features:**
- Case-insensitive matching
- Supports spaces in names
- Uses localized names (what you see in the UI)

### 2. Bundle Identifier

More precise than names, bundle IDs are unique:

```bash
peekaboo app launch --app com.microsoft.VSCode
peekaboo window close --app com.google.Chrome
```

**Features:**
- Exact matching only
- Always lowercase
- Guaranteed unique per application

### 3. Process ID (PID)

Direct process targeting using numeric IDs:

```bash
# Using --pid parameter
peekaboo app quit --pid 67890

# Using --app parameter with PID: prefix
peekaboo window focus --app "PID:67890"

# Finding PIDs
peekaboo app list --include-hidden --include-background  # Shows all PIDs
```

**Features:**
- Most precise targeting method
- Works even if app name is unknown
- Useful for scripting and automation

### 4. Fuzzy Name Matching

Peekaboo supports partial name matching for convenience:

```bash
# Matches "Visual Studio Code"
peekaboo see --no-elements --app "visual"
peekaboo see --no-elements --app "code"
peekaboo see --no-elements --app "studio"

# Matches "Google Chrome"
peekaboo window list --app chrome
```

**Algorithm:**
1. First tries exact match (case-insensitive)
2. Then tries "contains" match
3. Prioritizes running applications
4. Falls back to installed applications

## Selector safety and legacy leniency

V4 interaction and observation commands fail closed: use either `--app` or `--pid`, never both. This rule covers `see` and commands that use the shared interaction target such as `action`, `click`, `drag`, `press`, `set-value`, and `type`. These commands may observe, focus, and mutate through different services, so a redundant-looking pair is unsafe when those services resolve it differently.

Some legacy app/window management commands retain lenient parameter handling as a compatibility contract. For those commands, redundant app/PID information is accepted; a textual app selector remains authoritative because the synchronous resolver cannot reliably cross-check it against the PID.

### Mutation inventory completeness

App mutations require an exact name, exact bundle ID, or explicit PID. Name and bundle selection must prove uniqueness from a complete mutation inventory. Helpers with prohibited activation policy remain selectable by exact name or bundle when the runtime host can read their process generation, including helpers owned by another user when the host has that access. Duplicate readable helpers still make a matching name or bundle ambiguous.

The native mutation inventory excludes an unreadable helper without marking the inventory partial only when repeated observations agree: activation policy is explicitly prohibited, an exact-sized short-BSD response identifies the expected PID with an effective UID different from the runtime host, and full process-generation reads actually fail with `EPERM`. UID alone never predicts denial, and short BSD never supplies a generation receipt. Unknown policy, other failures, changing evidence, and a readable generation that disappears or changes all remain fail-closed. These checks share the inventory's one-second off-MainActor budget and retained native worker; they do not change read-only discovery or generation-pinned explicit-PID lifecycle targeting.

### Allowed Redundancy

These legacy management forms are valid and equivalent:
```bash
# Redundant PID specifications
peekaboo window close --app "PID:12345" --pid 12345

# Legacy compatibility: the textual app selector is authoritative
peekaboo window focus --app Safari --pid 67890
```

### Conflict Detection

This produces an error:
```bash
# Different PIDs
peekaboo window close --app "PID:12345" --pid 67890

```

A textual app/PID mismatch is not synchronously detectable in the legacy resolver. This is why interaction and observation commands reject the pair instead of choosing one.

## Implementation Details

### ApplicationResolvable Protocol

Commands with application parameters can conform to the `ApplicationResolvable` protocol:

```swift
protocol ApplicationResolvable {
    var app: String? { get }
    var pid: Int32? { get }
}
```

Safety-sensitive interaction call sites add stricter selector validation before invoking this resolver.

### Resolution Priority

When a legacy-compatible command accepts both `--app` and `--pid`:
1. If `--app` uses `PID:<pid>`, validate that it matches `--pid`
2. Otherwise, prefer the textual app or bundle identifier for the operation
3. Do not infer that an accompanying PID proves the textual app's identity

### Error Messages

Clear error messages help users understand issues:
- `"No application found with name 'Safarii'"` - Typo in name
- `"Application 'Safari' is not running"` - App not launched
- `"Process with PID 12345 not found or terminated"` - Invalid PID
- `"Application mismatch: --app 'Safari' does not match PID 12345 (Chrome)"` - Conflict

## Best Practices

### For Users

1. **Use names for readability**: `--app Safari` is clearer than `--app "PID:12345"`
2. **Use PIDs for precision**: When scripting or targeting specific instances
3. **Use bundle IDs for reliability**: When app names might be ambiguous

### For Scripts

```bash
# Get PID for scripting
PID=$(peekaboo app list --json --include-hidden --include-background | jq '.data.apps[] | select(.name=="Safari") | .pid')
peekaboo window close --pid $PID

# Or use bundle ID
peekaboo app launch --app com.apple.Safari
```

### For AI Agents

AI agents should provide exactly one of `--app` or `--pid`. Use `PID:<pid>` in `--app` only when a schema lacks a separate PID field. Do not send both unless the specific legacy command documents that compatibility form.

## Common Patterns

### Finding Applications

```bash
# List all running apps with PIDs
peekaboo app list --include-hidden --include-background

# Find specific app
peekaboo app list --include-hidden --include-background | grep -i safari
```

### Window Management

```bash
# List windows for an app
peekaboo window list --app Safari

# Focus specific window
peekaboo window focus --app Safari --window-title "GitHub"
```

### Cross-Space Operations

```bash
# Move window to current space (finds app by any method)
peekaboo space move-window --app Terminal --to-current
peekaboo space move-window --pid 12345 --to 2
```

## Troubleshooting

### Application Not Found

**Symptoms:**
- `"Application 'X' not found"`
- `"No running application matches 'X'"`

**Solutions:**
1. Check spelling: `peekaboo app list --include-hidden --include-background`
2. Try partial name: `--app chrome` instead of `--app "Google Chrome"`
3. Use bundle ID: `--app com.google.Chrome`
4. Use PID directly: Find it with `peekaboo app list --include-hidden --include-background`, then use `--pid`

### PID Issues

**Symptoms:**
- `"Process with PID X not found"`
- `"Invalid PID format"`

**Solutions:**
1. Verify PID is current: `peekaboo app list --include-hidden --include-background`
2. Check format: `--app "PID:12345"` needs quotes and prefix
3. Use `--pid 12345` for direct numeric PIDs

### Multiple Matches

**Symptoms:**
- Fuzzy matching finds wrong app
- Multiple apps with similar names

**Solutions:**
1. Use full name: `--app "Visual Studio Code"` not `--app code`
2. Use bundle ID for precision
3. Use PID for exact targeting

## See Also

- [Command index](commands/README.md) - Full command documentation
- [Agent chat](agent-chat.md) - Using Peekaboo with AI agents
- [Automation guide](automation.md) - Scripting and automation patterns
