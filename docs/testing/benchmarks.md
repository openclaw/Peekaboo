---
summary: 'Run local Peekaboo command microbenchmarks without persistent telemetry.'
read_when:
  - 'measuring local command latency before or after a performance change'
  - 'preparing benchmark evidence for a Peekaboo PR'
---

# Local command benchmarks

Peekaboo keeps performance evidence local and explicit. Use the benchmark helper when you need repeatable
numbers for a command, especially after changing capture, observation, targeting, or input paths.

This is not telemetry. It does not install a background collector, write a global database, or send anything
over the network. It runs a command N times and writes JSON artifacts under `.artifacts/` so you can inspect or
share the specific run when needed.

## Quick start

Build a debug CLI once:

```bash
pnpm run build:cli
BIN="$(swift build --package-path Apps/CLI --show-bin-path)/peekaboo"
```

Run a UI-free smoke benchmark:

```bash
pnpm run benchmark:tools \
  --name tools-json \
  --runs 5 \
  --warmups 1 \
  --bin "$BIN" \
  -- tools --json-output
```

The summary path is printed at the end:

```text
.artifacts/playground-tools/20260517T021530Z-tools-json-summary.json
```

## Playground fixture benchmarks

For UI commands, use the Playground fixture windows so each run targets the same app/window shape.

1. Build and open the Playground app.
2. Open the relevant fixture window from the Playground `Fixtures` menu.
3. Run the benchmark against the fixture title or a snapshot captured from that fixture.

Example `see` benchmark:

```bash
pnpm run benchmark:tools \
  --name see-click-fixture \
  --runs 10 \
  --warmups 1 \
  --bin "$BIN" \
  -- see --app boo.peekaboo.playground.debug --mode window --window-title "Click Fixture" --json-output
```

Example `menu` benchmark:

```bash
pnpm run benchmark:tools \
  --name menu-list-all-playground \
  --runs 5 \
  --warmups 1 \
  --bin "$BIN" \
  -- menu list-all --app boo.peekaboo.playground.debug --json-output
```

## How to read the summary

- `wall_time` measures total process/runtime time from the helper's perspective.
- `execution_time` uses the command's own JSON timing field when the command exposes one.
- `warmup` runs are saved but excluded from the reported statistics.
- `failures` lists measured runs with non-zero exit codes.
- The helper exits non-zero when measured runs fail unless you pass `--allow-failures`.
- The summary includes the command arguments after replacing the current checkout path with `.` and `$HOME` with
  `~`; avoid benchmarking commands with secrets or sensitive local paths if you plan to share the artifacts.

Use p95 for regressions and PR evidence. Avoid hard thresholds in unit tests; command latency depends on host load,
permissions, active windows, display count, and whether the daemon/Bridge path is warm.
