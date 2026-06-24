---
summary: 'Review Peekaboo Logging Guide guidance'
read_when:
  - 'planning work related to peekaboo logging guide'
  - 'debugging or extending features described here'
---

# Peekaboo Logging Guide

## Overview

Peekaboo implements a comprehensive logging system designed to help developers and users debug automation scripts, understand performance characteristics, and troubleshoot issues. The logging system provides structured, timestamped output with multiple log levels and categories.

## Log Levels

Peekaboo supports the following log levels (from most to least verbose):

- **VERBOSE**: Detailed information about internal operations, decision-making, and timing
- **DEBUG**: Debugging information useful for development
- **INFO**: General informational messages
- **WARN**: Warning messages for potentially problematic situations
- **ERROR**: Error messages for failures and exceptions

## Enabling Verbose Logging

### Command Line Flag

Use the `--verbose` or `-v` flag with any command:

```bash
peekaboo see --app Safari --verbose
peekaboo click --on "$ELEMENT_ID" --verbose
```

### Environment Variable

Set the `PEEKABOO_LOG_LEVEL` environment variable:

```bash
export PEEKABOO_LOG_LEVEL=verbose
peekaboo see --app Safari
```

Valid values: `verbose`, `trace`, `debug`, `info`, `warning`, `warn`, `error`

## Log Output Format

When verbose logging is enabled, messages are output to stderr in the following format:

```
[2025-01-06T08:05:23.123Z] VERBOSE: Message here
[2025-01-06T08:05:23.456Z] VERBOSE [Category]: Message with category
[2025-01-06T08:05:23.789Z] VERBOSE [Performance]: Timer 'operation' completed {duration_ms=234}
```

### Components:
- **Timestamp**: ISO 8601 format with milliseconds
- **Level**: Log level (VERBOSE, DEBUG, INFO, WARN, ERROR)
- **Category** (optional): Logical grouping of related messages
- **Message**: The log message
- **Metadata** (optional): Additional structured data in key=value format

## Log Categories

Common log categories used throughout Peekaboo:

- **Permissions**: Permission checking and status
- **Capture**: Screenshot capture operations
- **WindowSearch**: Window finding and matching
- **ElementDetection**: UI element detection and analysis
- **Snapshot**: Snapshot cache management operations
- **Performance**: Performance timing and metrics
- **Operation**: High-level operation tracking
- **AI**: AI provider operations and analysis

## Performance Tracking

Verbose mode automatically tracks and reports performance metrics:

```
[2025-01-06T08:05:23.123Z] VERBOSE [Performance]: Starting timer 'screen_capture'
[2025-01-06T08:05:23.456Z] VERBOSE [Performance]: Timer 'screen_capture' completed {duration_ms=333}
```

This helps identify performance bottlenecks and slow operations.

## Examples

### Basic Verbose Output

```bash
$ peekaboo see --app Safari --verbose
[2025-01-06T08:05:23.123Z] VERBOSE: Verbose logging enabled
[2025-01-06T08:05:23.124Z] VERBOSE [Operation]: Starting operation {operation=see_command, app=Safari, mode=auto, annotate=false, hasAnalyzePrompt=false}
[2025-01-06T08:05:23.125Z] VERBOSE [Permissions]: Checking screen recording permissions
[2025-01-06T08:05:23.200Z] VERBOSE [Permissions]: Screen recording permission granted
[2025-01-06T08:05:23.201Z] VERBOSE [Capture]: Starting capture and detection phase
[2025-01-06T08:05:23.202Z] VERBOSE [Capture]: Determined capture mode {mode=window}
[2025-01-06T08:05:23.203Z] VERBOSE [Capture]: Initiating window capture {app=Safari, windowTitle=any}
[2025-01-06T08:05:23.204Z] VERBOSE [Performance]: Starting timer 'window_capture'
[2025-01-06T08:05:23.537Z] VERBOSE [Performance]: Timer 'window_capture' completed {duration_ms=333}
[2025-01-06T08:05:23.538Z] VERBOSE [Capture]: Capture completed successfully {snapshotId=12345, elementCount=42, screenshotSize=524288}
[2025-01-06T08:05:23.750Z] VERBOSE [Operation]: Operation completed {operation=see_command, success=true, executionTimeMs=627}
```

### Debugging Element Not Found

```bash
$ peekaboo click --on "$ELEMENT_ID" --verbose
[2025-01-06T08:05:24.123Z] VERBOSE [Snapshot]: Resolving snapshot {explicitId=null}
[2025-01-06T08:05:24.124Z] VERBOSE [Snapshot]: Found valid snapshots {count=1, latest=12345}
[2025-01-06T08:05:24.125Z] VERBOSE [ElementSearch]: Looking for element {id=<element-id>, snapshotId=12345}
[2025-01-06T08:05:24.126Z] VERBOSE [ElementSearch]: Loading snapshot map from cache
[2025-01-06T08:05:24.127Z] ERROR [ElementSearch]: Element not found in snapshot {id=<element-id>}
```

### Performance Analysis

```bash
$ peekaboo see --mode screen --annotate --verbose
[2025-01-06T08:05:25.123Z] VERBOSE [Performance]: Starting timer 'screen_capture'
[2025-01-06T08:05:26.456Z] VERBOSE [Performance]: Timer 'screen_capture' completed {duration_ms=1333}
[2025-01-06T08:05:26.457Z] VERBOSE [Performance]: Starting timer 'element_detection'
[2025-01-06T08:05:27.234Z] VERBOSE [Performance]: Timer 'element_detection' completed {duration_ms=777}
[2025-01-06T08:05:27.235Z] VERBOSE [Performance]: Starting timer 'generate_annotations'
[2025-01-06T08:05:27.567Z] VERBOSE [Performance]: Timer 'generate_annotations' completed {duration_ms=332}
```

## JSON Output Mode

When using `--json`, verbose logs are collected in the `debug_logs` array:

```json
{
  "success": true,
  "data": {
    "snapshot_id": "12345"
  },
  "debug_logs": [
    "[2025-01-06T08:05:23.123Z] VERBOSE: Verbose logging enabled",
    "[2025-01-06T08:05:23.124Z] VERBOSE [Operation]: Starting operation {operation=see_command}"
  ]
}
```

## Best Practices

1. **Use verbose mode when debugging** automation scripts to understand why elements aren't found or operations fail

2. **Check performance logs** to identify slow operations that might benefit from optimization

3. **Look for error patterns** in categories like WindowSearch or ElementDetection to understand common issues

4. **Use environment variables** for consistent logging across multiple commands in scripts

5. **Filter logs by category** when troubleshooting specific subsystems

## Integration with Other Tools

### Filtering Logs

Use standard Unix tools to filter verbose output:

```bash
# Show only Performance logs
peekaboo see --verbose 2>&1 | grep "Performance"

# Show only errors
peekaboo see --verbose 2>&1 | grep "ERROR"

# Save logs to file
peekaboo see --verbose 2> peekaboo.log
```

### Structured Log Processing

The consistent format makes it easy to process logs programmatically:

```bash
# Extract all operation durations
peekaboo see --verbose 2>&1 | grep "duration_ms" | sed 's/.*duration_ms=\([0-9]*\).*/\1/'
```

## Troubleshooting

### No Verbose Output

If you don't see verbose output:
1. Ensure you're using `--verbose` flag or set `PEEKABOO_LOG_LEVEL=verbose`
2. Check that output isn't being redirected (logs go to stderr, not stdout)
3. Verify you're not using `--json` (logs go to debug_logs array in JSON mode)

### Performance Issues

If verbose logging shows slow operations:
1. Check "Timer completed" messages for operations taking >1000ms
2. Look for repeated operations that could be optimized
3. Consider using more specific targeting (e.g., window title) to reduce search time
