---
summary: 'Use and interpret Peekaboo CLI logging'
read_when:
  - 'debugging CLI execution or structured output'
  - 'adding log levels, categories, or performance timers'
---

# Peekaboo Logging Guide

## Overview

The CLI logger writes timestamped diagnostic messages to stderr in text mode and buffers the same messages for `debug_logs` in JSON mode. It supports free-form categories and key/value metadata.

## Log Levels

Peekaboo supports these levels from most to least verbose:

- **TRACE**
- **VERBOSE**
- **DEBUG**
- **INFO**
- **WARN**
- **ERROR**
- **CRITICAL**

The default minimum is `warning` unless `PEEKABOO_LOG_LEVEL` overrides it.

## Enabling Verbose Logging

### Command Line Flag

Use `--verbose` or `-v` on commands that expose the global runtime options:

```bash
peekaboo see --app Safari --verbose
peekaboo click --on "$ELEMENT_ID" --verbose
```

### Environment Variable

```bash
PEEKABOO_LOG_LEVEL=debug peekaboo see --app Safari
```

Accepted values are `trace`, `verbose`, `debug`, `info`, `warning`/`warn`, `error`, and `critical`.

## Log Output Format

The CLI logger formats text as:

```text
[2026-08-08T12:34:56.789Z] VERBOSE: Message
[2026-08-08T12:34:56.789Z] VERBOSE [Capture]: Message {app=Safari, mode=window}
```

The timestamp is ISO 8601 with fractional seconds. Category and metadata are optional. Metadata ordering is not an API contract because it comes from a Swift dictionary.

## Log Categories

Categories are strings supplied by call sites rather than a central enum. Current CLI code uses categories including `AI`, `Automation`, `Bridge`, `Capture`, `Commander`, `Menu`, `MultiScreen`, `Operation`, and `Performance`.

The separate automation event logger uses Apple's unified logging for command activity; it does not change the stderr/JSON format above.

## Performance Tracking

`Logger.startTimer(_:)` records a start time. `stopTimer(_:threshold:)` prepares a `Performance` message when verbose mode is active or a supplied threshold is exceeded; the configured minimum level still controls whether that verbose message is emitted:

```text
[2026-08-08T12:34:56.789Z] VERBOSE [Performance]: Starting timer 'screen_capture'
[2026-08-08T12:34:57.122Z] VERBOSE [Performance]: Timer 'screen_capture' completed {duration_ms=333}
```

`operationStart` and `operationComplete` wrap this timer behavior and add `Operation` metadata.

## JSON Output Mode

When a command enables JSON output, the logger buffers messages instead of writing them beside the JSON document. Standard CLI response types include those buffered strings in `debug_logs`:

```json
{
  "success": true,
  "data": {},
  "debug_logs": []
}
```

`--json-output` does not automatically lower the log threshold. Combine it with `--verbose` or `PEEKABOO_LOG_LEVEL` when detailed buffered logs are needed.

## Best Practices

1. Use verbose or debug logging while reproducing automation failures.
2. Add a category only when it helps isolate an owning subsystem.
3. Keep metadata small and non-sensitive; it is printed in text mode and returned in JSON mode.
4. Use timers for measured operations, not as a substitute for profiling.

## Integration with Other Tools

### Filtering Logs

```bash
peekaboo see --verbose 2>&1 | rg 'Performance'
peekaboo see --verbose 2>peekaboo.log
```

For JSON output, inspect `.debug_logs` instead of mixing diagnostics into stdout:

```bash
peekaboo see --app Safari --json-output --verbose | jq '.debug_logs'
```

## Troubleshooting

### No Verbose Output

1. Confirm the command accepts `--verbose`, or set `PEEKABOO_LOG_LEVEL=verbose`.
2. In text mode, check stderr rather than stdout.
3. In JSON mode, inspect `debug_logs`.
