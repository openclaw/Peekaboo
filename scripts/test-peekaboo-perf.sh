#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/fake-peekaboo"
cat >"$FAKE_BIN" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "fail" ]]; then
  echo '{"success":false,"data":{"execution_time":0.02}}'
  exit 7
fi

if [[ "${1:-}" == "softfail" ]]; then
  echo '{"success":false,"data":{"execution_time":0.03}}'
  exit 0
fi

echo '{"success":true,"data":{"execution_time":0.01}}'
EOF
chmod +x "$FAKE_BIN"

"$ROOT/Apps/Playground/scripts/peekaboo-perf.sh" \
  --name smoke \
  --runs 3 \
  --warmups 1 \
  --log-root "$TMP_DIR/smoke" \
  --bin "$FAKE_BIN" \
  -- ok "$ROOT/private-fixture.json" --json-output >/tmp/peekaboo-perf-smoke.log

SMOKE_SUMMARY="$(find "$TMP_DIR/smoke" -name '*-smoke-summary.json' -print -quit)"
python3 - "$SMOKE_SUMMARY" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1]))
assert summary["name"] == "smoke"
assert summary["run_count"] == 3
assert summary["warmup_count"] == 1
assert summary["execution_time"]["n"] == 3
assert summary["wall_time"]["n"] == 3
assert "stddev_s" in summary["execution_time"]
assert "stddev_s" in summary["wall_time"]
assert summary["failures"] == []
assert summary["binary"] == "fake-peekaboo"
assert summary["command"] == ["ok", "./private-fixture.json", "--json-output"]
assert "git_branch" not in summary["environment"]
PY

PWNED_SUBSHELL="$TMP_DIR/pwned-subshell"
PWNED_BACKTICK="$TMP_DIR/pwned-backtick"
"$ROOT/Apps/Playground/scripts/peekaboo-perf.sh" \
  --name shell-safe \
  --runs 1 \
  --log-root "$TMP_DIR/shell-safe" \
  --bin "$FAKE_BIN" \
  -- ok \
  "arg with spaces" \
  "semi;colon" \
  "\$(touch $PWNED_SUBSHELL)" \
  "\`touch $PWNED_BACKTICK\`" \
  --json-output >/tmp/peekaboo-perf-shell-safe.log

if [[ -e "$PWNED_SUBSHELL" || -e "$PWNED_BACKTICK" ]]; then
  echo "Benchmark helper executed shell metacharacters from command arguments" >&2
  exit 1
fi

SHELL_SAFE_SUMMARY="$(find "$TMP_DIR/shell-safe" -name '*-shell-safe-summary.json' -print -quit)"
python3 - "$SHELL_SAFE_SUMMARY" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1]))
assert summary["command"][0:3] == ["ok", "arg with spaces", "semi;colon"]
assert summary["command"][-1] == "--json-output"
assert any("$(touch " in arg for arg in summary["command"])
assert any("`touch " in arg for arg in summary["command"])
assert summary["execution_time"]["n"] == 1
assert summary["execution_time"]["stddev_s"] is None
assert summary["wall_time"]["n"] == 1
assert summary["wall_time"]["stddev_s"] is None
PY

set +e
"$ROOT/Apps/Playground/scripts/peekaboo-perf.sh" \
  --name failing \
  --runs 1 \
  --log-root "$TMP_DIR/failing" \
  --bin "$FAKE_BIN" \
  -- fail >/tmp/peekaboo-perf-failing.log 2>&1
FAILING_STATUS="$?"
set -e

if [[ "$FAILING_STATUS" -eq 0 ]]; then
  echo "Expected failing benchmark to exit non-zero" >&2
  exit 1
fi

set +e
"$ROOT/Apps/Playground/scripts/peekaboo-perf.sh" \
  --name bad-warmup \
  --runs 1 \
  --warmups 08 \
  --log-root "$TMP_DIR/bad-warmup" \
  --bin "$FAKE_BIN" \
  -- ok >/tmp/peekaboo-perf-bad-warmup.log 2>&1
BAD_WARMUP_STATUS="$?"
set -e

if [[ "$BAD_WARMUP_STATUS" -eq 0 ]]; then
  echo "Expected leading-zero warmup count to fail validation" >&2
  exit 1
fi

"$ROOT/Apps/Playground/scripts/peekaboo-perf.sh" \
  --name allowed \
  --runs 1 \
  --allow-failures \
  --log-root "$TMP_DIR/allowed" \
  --bin "$FAKE_BIN" \
  -- fail >/tmp/peekaboo-perf-allowed.log

ALLOWED_SUMMARY="$(find "$TMP_DIR/allowed" -name '*-allowed-summary.json' -print -quit)"
python3 - "$ALLOWED_SUMMARY" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1]))
assert len(summary["failures"]) == 1
assert summary["failures"][0]["exit_code"] == 7
assert summary["failures"][0]["reason"] == "exit_code"
assert summary["execution_time"] is None
assert summary["wall_time"] is None
PY

"$ROOT/Apps/Playground/scripts/peekaboo-perf.sh" \
  --name softfail \
  --runs 1 \
  --allow-failures \
  --log-root "$TMP_DIR/softfail" \
  --bin "$FAKE_BIN" \
  -- softfail >/tmp/peekaboo-perf-softfail.log

SOFTFAIL_SUMMARY="$(find "$TMP_DIR/softfail" -name '*-softfail-summary.json' -print -quit)"
python3 - "$SOFTFAIL_SUMMARY" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1]))
assert len(summary["failures"]) == 1
assert summary["failures"][0]["exit_code"] == 0
assert summary["failures"][0]["reason"] == "success_false"
assert summary["execution_time"] is None
assert summary["wall_time"] is None
PY

echo "test-peekaboo-perf: ok"
