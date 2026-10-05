# pblog - Peekaboo Log Viewer

A unified log viewer for all Peekaboo applications and services.

## Quick Start

```bash
# Show recent logs from all Peekaboo subsystems
./scripts/pblog.sh

# Stream logs continuously
./scripts/pblog.sh -f

# Show only errors
./scripts/pblog.sh -e

# Show logs from a specific service
./scripts/pblog.sh -c ElementDetectionService

# Show logs from a specific subsystem
./scripts/pblog.sh --subsystem boo.peekaboo.core
```

## Supported Subsystems

- `boo.peekaboo.core` - Core services (ClickService, ElementDetectionService, etc.)
- `boo.peekaboo.cli` - CLI tool
- `boo.peekaboo.inspector` - Inspector app
- `boo.peekaboo.playground` - Playground test app
- `boo.peekaboo.app` - Main Mac app
- `boo.peekaboo` - Mac app components

## Options

- `-n, --lines NUM` - Number of lines to show (default: 50)
- `-l, --last TIME` - Time range to search (default: 5m)
- `-c, --category CAT` - Filter by category (e.g., ClickService)
- `-s, --search TEXT` - Search for specific text
- `-d, --debug` - Show debug level logs
- `-f, --follow` - Stream logs continuously
- `-e, --errors` - Show only errors
- Historical error queries match the native `logType` field; unrelated event types are not log severity.
- `--subsystem NAME` - Filter by specific subsystem
- `--json` - Output in JSON format

Search, category, and subsystem values are literal text, not shell commands or predicate expressions. Quote values in your shell; the helper preserves apostrophes, quotes, backslashes, and trailing newlines when passing them to macOS unified logging. macOS can reject control characters in a predicate; the helper does not silently trim them into a different query. `--output FILE` saves the selected rows to a file; `--all` disables the default tail limit.

Failed log queries return nonzero even when output is limited with `tail` or saved to a file. Passwordless-sudo refusals, invalid tail limits, and output-file errors also remain failures; partial output is not a success signal.

## Examples

Value-taking options require a following argument. A final `--search`, `--lines`, or other value-taking option reports `<option> requires a value` on stderr and exits with status 2 before reading logs. Empty or dash-prefixed arguments are still supplied values, not missing arguments.

```bash
# Debug element detection issues
./scripts/pblog.sh -c ElementDetectionService -d

# Monitor click operations
./scripts/pblog.sh -c ClickService -f

# Check recent errors
./scripts/pblog.sh -e -l 30m

# Search for specific text
./scripts/pblog.sh -s "Dialog" -n 100

# Monitor Playground app logs
./scripts/pblog.sh --subsystem boo.peekaboo.playground -f
```

`--lines` limits completed text queries. JSON output preserves the producer's
framing, and `--follow` forwards events without waiting for the stream to end.
Both modes bypass the physical-line tail limit; live JSON is not necessarily
one standalone JSON document.
