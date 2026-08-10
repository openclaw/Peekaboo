---
summary: 'Review Application Resolution in Peekaboo guidance'
read_when:
  - 'planning work related to application resolution in peekaboo'
  - 'debugging or extending features described here'
---

# Application Resolution in Peekaboo

This document explains how Peekaboo resolves applications across all commands that accept an application parameter.

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

# Both parameters (when they refer to the same app)
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

## Lenient Parameter Handling

Peekaboo is designed to be forgiving with parameters, especially for AI agents that might provide redundant information.

### Allowed Redundancy

These are all valid and equivalent:
```bash
# Redundant PID specifications
peekaboo window close --app "PID:12345" --pid 12345

# Name and PID for same app
peekaboo see --no-elements --app Safari --pid 67890  # If PID 67890 is Safari
```

### Conflict Detection

These will produce errors:
```bash
# Different PIDs
peekaboo window close --app "PID:12345" --pid 67890

# Name doesn't match PID
peekaboo see --no-elements --app Safari --pid 12345  # If PID 12345 is Chrome
```

## Implementation Details

### ApplicationResolvable Protocol

All commands with application parameters conform to the `ApplicationResolvable` protocol:

```swift
protocol ApplicationResolvable {
    var app: String? { get }
    var pid: Int32? { get }
}
```

This ensures consistent behavior across all commands.

### Resolution Priority

When both `--app` and `--pid` are provided:
1. Validate they refer to the same application
2. Prefer the more readable format (name/bundle) for operations
3. Use PID for precise targeting when needed

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

AI agents can safely:
- Provide both `--app` and `--pid` if unsure
- Use PID format in either parameter
- Mix formats as needed

The lenient validation ensures the command works if the parameters are consistent.

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
