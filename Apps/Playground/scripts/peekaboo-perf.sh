#!/bin/bash

set -euo pipefail

NAME=""
RUNS=10
WARMUPS=0
LOG_ROOT="${LOG_ROOT:-$PWD/.artifacts/playground-tools}"
BIN="${PEEKABOO_BIN:-$PWD/peekaboo}"
ALLOW_FAILURES=0

usage() {
  cat <<'EOF'
Usage: peekaboo-perf.sh --name <slug> [--runs N] [--warmups N] [--log-root DIR] [--bin PATH] [--allow-failures] -- <peekaboo args...>

Runs a Peekaboo CLI command repeatedly, captures per-run JSON output, and writes a summary JSON
with mean/median/p95/min/max based on command execution time when present and wall time otherwise.

The helper is local-only: it writes under .artifacts by default, sends nothing anywhere, and is not a
telemetry subsystem. Failed measured runs make the helper exit non-zero unless --allow-failures is set.

Examples:
  pnpm run benchmark:tools --name see-click-fixture --runs 10 --warmups 1 --bin ./Apps/CLI/.build/debug/peekaboo -- \
    see --app boo.peekaboo.playground.debug --mode window --window-title "Click Fixture" --json-output

  pnpm run benchmark:tools --name click-single --runs 20 --bin ./Apps/CLI/.build/debug/peekaboo -- \
    click "Single Click" --snapshot <id> --app boo.peekaboo.playground.debug --json-output
EOF
}

is_nonnegative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      NAME="${2:-}"
      shift 2
      ;;
    --runs)
      RUNS="${2:-}"
      shift 2
      ;;
    --warmups|--warmup)
      WARMUPS="${2:-}"
      shift 2
      ;;
    --log-root)
      LOG_ROOT="${2:-}"
      shift 2
      ;;
    --bin)
      BIN="${2:-}"
      shift 2
      ;;
    --allow-failures)
      ALLOW_FAILURES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "--name is required" >&2
  usage >&2
  exit 2
fi

if [[ ! "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "--name must contain only letters, numbers, dots, underscores, or hyphens" >&2
  exit 2
fi

if ! is_positive_int "$RUNS"; then
  echo "--runs must be a positive integer" >&2
  exit 2
fi

if ! is_nonnegative_int "$WARMUPS"; then
  echo "--warmups must be a non-negative integer" >&2
  exit 2
fi

if [[ $# -eq 0 ]]; then
  echo "Missing peekaboo args after --" >&2
  usage >&2
  exit 2
fi

if [[ ! -x "$BIN" ]]; then
  echo "Peekaboo binary not executable: $BIN" >&2
  echo "Tip: set PEEKABOO_BIN=/path/to/peekaboo or pass --bin" >&2
  exit 2
fi

mkdir -p "$LOG_ROOT"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
SUMMARY="$LOG_ROOT/${TS}-${NAME}-summary.json"

COMMAND_ARGS_JSON="$(python3 - "$@" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1:]))
PY
)"

echo "Running benchmark:"
echo "- name: $NAME"
echo "- measured runs: $RUNS"
echo "- warmups: $WARMUPS"
echo "- bin: $BIN"
echo "- out: $LOG_ROOT"
echo "- cmd: $*"

now_seconds() {
  python3 - <<'PY'
import time

print(time.time())
PY
}

write_payload() {
  local out="$1"
  local phase="$2"
  local iteration="$3"
  local wall="$4"
  local exit_code="$5"

  PEEKABOO_PERF_OUT="$out" \
  PEEKABOO_PERF_PHASE="$phase" \
  PEEKABOO_PERF_ITERATION="$iteration" \
  PEEKABOO_PERF_WALL="$wall" \
  PEEKABOO_PERF_EXIT="$exit_code" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["PEEKABOO_PERF_OUT"])
raw = path.read_text(errors="replace")
try:
    payload = json.loads(raw)
except Exception:
    payload = {"success": False, "data": {}, "raw_output": raw}

if not isinstance(payload, dict):
    payload = {"success": False, "data": {}, "raw_output": raw}

data = payload.get("data")
if not isinstance(data, dict):
    data = {}
    payload["data"] = data

data["wall_time"] = float(os.environ["PEEKABOO_PERF_WALL"])
data["exit_code"] = int(os.environ["PEEKABOO_PERF_EXIT"])
data["benchmark"] = {
    "phase": os.environ["PEEKABOO_PERF_PHASE"],
    "iteration": int(os.environ["PEEKABOO_PERF_ITERATION"]),
}

path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

run_one() {
  local phase="$1"
  local iteration="$2"
  shift 2
  local out="$LOG_ROOT/${TS}-${NAME}-${phase}-${iteration}.json"

  local start
  local end
  local wall
  local exit_code

  start="$(now_seconds)"
  set +e
  "$BIN" "$@" >"$out"
  exit_code="$?"
  set -e
  end="$(now_seconds)"

  wall="$(python3 - <<PY
start = float("$start")
end = float("$end")
print(end - start)
PY
)"

  write_payload "$out" "$phase" "$iteration" "$wall" "$exit_code"

  if [[ "$exit_code" -ne 0 ]]; then
    echo "- $phase $iteration failed (exit=$exit_code): $out" >&2
  else
    echo "- $phase $iteration -> $out (wall=${wall}s)"
  fi
}

if (( WARMUPS > 0 )); then
  for i in $(seq 1 "$WARMUPS"); do
    run_one "warmup" "$i" "$@"
  done
fi

for i in $(seq 1 "$RUNS"); do
  run_one "run" "$i" "$@"
done

PEEKABOO_PERF_LOG_ROOT="$LOG_ROOT" \
PEEKABOO_PERF_SUMMARY="$SUMMARY" \
PEEKABOO_PERF_NAME="$NAME" \
PEEKABOO_PERF_TS="$TS" \
PEEKABOO_PERF_RUNS="$RUNS" \
PEEKABOO_PERF_WARMUPS="$WARMUPS" \
PEEKABOO_PERF_ALLOW_FAILURES="$ALLOW_FAILURES" \
PEEKABOO_PERF_BIN_NAME="$(basename "$BIN")" \
PEEKABOO_PERF_COMMAND_ARGS_JSON="$COMMAND_ARGS_JSON" \
  python3 - <<'PY'
import glob
import json
import math
import os
import platform
import subprocess
import sys
from pathlib import Path

log_root = os.environ["PEEKABOO_PERF_LOG_ROOT"]
summary_path = Path(os.environ["PEEKABOO_PERF_SUMMARY"])
name = os.environ["PEEKABOO_PERF_NAME"]
timestamp = os.environ["PEEKABOO_PERF_TS"]
allow_failures = os.environ["PEEKABOO_PERF_ALLOW_FAILURES"] == "1"
command_args = json.loads(os.environ["PEEKABOO_PERF_COMMAND_ARGS_JSON"])


def sanitize_text(value):
    result = str(value)
    cwd = str(Path.cwd().resolve())
    home = os.environ.get("HOME")
    if cwd:
        result = result.replace(cwd, ".")
    if home:
        result = result.replace(home, "~")
    return result


def display_path(path):
    raw = Path(path)
    try:
        return str(raw.resolve().relative_to(Path.cwd().resolve()))
    except Exception:
        return sanitize_text(raw)


def display_pattern(phase):
    root = display_path(log_root)
    return f"{root}/{timestamp}-{name}-{phase}-*.json"


def percentile(sorted_values, pct):
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return sorted_values[0]
    k = (len(sorted_values) - 1) * pct
    floor_index = math.floor(k)
    ceil_index = math.ceil(k)
    if floor_index == ceil_index:
        return sorted_values[int(k)]
    low = sorted_values[floor_index] * (ceil_index - k)
    high = sorted_values[ceil_index] * (k - floor_index)
    return low + high


def stats(values):
    values_sorted = sorted(values)
    if not values_sorted:
        return None
    return {
        "n": len(values_sorted),
        "samples_s": values_sorted,
        "mean_s": sum(values_sorted) / len(values_sorted),
        "median_s": percentile(values_sorted, 0.50),
        "p95_s": percentile(values_sorted, 0.95),
        "min_s": values_sorted[0],
        "max_s": values_sorted[-1],
    }


def git_value(args):
    try:
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None


def load_payloads(phase):
    paths = sorted(glob.glob(f"{log_root}/{timestamp}-{name}-{phase}-*.json"))
    payloads = []
    for path in paths:
        payload = json.loads(Path(path).read_text())
        payloads.append((path, payload))
    return payloads


def collect(payloads):
    execution_times = []
    wall_times = []
    failures = []
    for path, payload in payloads:
        data = payload.get("data", {}) or {}
        exit_code = int(data.get("exit_code", 0))
        if exit_code != 0:
            failures.append({"path": display_path(path), "exit_code": exit_code, "reason": "exit_code"})
        elif payload.get("success") is False:
            failures.append({"path": display_path(path), "exit_code": exit_code, "reason": "success_false"})

        exec_time = data.get("execution_time")
        if exec_time is None:
            exec_time = data.get("executionTime")
        if exec_time is None:
            exec_time = data.get("execution_time_s")
        if exec_time is None:
            exec_time = data.get("executionTimeSeconds")

        wall_time = data.get("wall_time")
        if isinstance(exec_time, (int, float)):
            execution_times.append(float(exec_time))
        if isinstance(wall_time, (int, float)):
            wall_times.append(float(wall_time))

    return execution_times, wall_times, failures


measured_payloads = load_payloads("run")
warmup_payloads = load_payloads("warmup")
execution_times, wall_times, failures = collect(measured_payloads)

summary = {
    "name": name,
    "timestamp": timestamp,
    "binary": os.environ["PEEKABOO_PERF_BIN_NAME"],
    "command": [sanitize_text(arg) for arg in command_args],
    "run_count": int(os.environ["PEEKABOO_PERF_RUNS"]),
    "warmup_count": int(os.environ["PEEKABOO_PERF_WARMUPS"]),
    "measured_pattern": display_pattern("run"),
    "warmup_pattern": display_pattern("warmup"),
    "execution_time": stats(execution_times),
    "wall_time": stats(wall_times),
    "failures": failures,
    "environment": {
        "platform": platform.platform(),
        "python": platform.python_version(),
        "git_commit": git_value(["rev-parse", "--short", "HEAD"]),
    },
}

summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")

print(str(summary_path))
if failures and not allow_failures:
    print(f"Benchmark failed: {len(failures)} measured run(s) exited non-zero", file=sys.stderr)
    sys.exit(1)
PY

echo "Summary: $SUMMARY"
