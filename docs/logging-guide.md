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

Detached native AX observations have a debug-only unified-log category, `AXObservation`, under `boo.peekaboo.core`.
Capture it for the executing CLI or Bridge host while reproducing a slow or incomplete read:

```bash
log stream --level debug --predicate 'processIdentifier == 12345 AND subsystem == "boo.peekaboo.core" AND category == "AXObservation"'
```

Replace `12345` with the verified executing host PID. These records report native call type, traversal-node ordinal,
elapsed milliseconds, raw AX errors, fixed attribute names for embedded errors, batch counts/fallbacks, and total worker
time. Node zero denotes reads outside traversal. Fast successful reads are omitted; calls taking at least 50 ms and
failed/fallback reads are retained. No UI values, labels, identifiers or action names are logged, and no additional AX
queries are performed. This stream is separate from CLI `debug_logs`; it does not require a private-data logging profile.

## Performance Tracking

`Logger.startTimer(_:)` records a start time. `stopTimer(_:threshold:)` prepares a `Performance` message when verbose mode is active or a supplied threshold is exceeded; the configured minimum level still controls whether that verbose message is emitted:

```text
[2026-08-08T12:34:56.789Z] VERBOSE [Performance]: Starting timer 'screen_capture'
[2026-08-08T12:34:57.122Z] VERBOSE [Performance]: Timer 'screen_capture' completed {duration_ms=333}
```

`operationStart` and `operationComplete` wrap this timer behavior and add `Operation` metadata.

### Agent phase timing

The Agent runtime separately emits content-free debug records through unified logging under subsystem
`boo.peekaboo`, category `agent`. Capture them for the verified executing Agent process without enabling verbose
payload logging:

```bash
log stream --level debug --predicate 'processIdentifier == 12345 AND subsystem == "boo.peekaboo" AND category == "agent" AND eventMessage BEGINSWITH "phase="'
```

Each completed phase emits only a fixed phase name, zero-based model-step number, monotonic elapsed milliseconds,
and `success`, `error`, or `cancelled` status:

```text
phase=provider_stream step=0 elapsed_ms=1234.5 status=success
phase=tool step=0 elapsed_ms=42.0 status=success
```

`provider_stream` covers stream setup and consumption, including event delivery during consumption;
`provider_generate` covers the non-streaming provider call. `tool` covers actual tool execution, including optional
verification, and uses the runtime's existing tool-failure classification. Calls skipped before execution emit no tool
timing. Phase completion is not task completion or proof that a native mutation was confirmed.

These are inclusive wall-time intervals, not CPU or model-reasoning measurements. Context preparation, session writes,
and work outside these boundaries remain unmeasured. Concurrent runs in the same process are not distinguished by a
session identifier, so do not assign their interleaved records to one run or add overlapping durations as exclusive time.
The records contain no model names, prompts, tool names, arguments, results, paths, or session/call identifiers. They do
not change CLI `debug_logs`, execution traces, or saved sessions, and need no private-data logging profile.

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
