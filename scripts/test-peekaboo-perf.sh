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
assert summary["failures"] == []
assert summary["binary"] == "fake-peekaboo"
assert summary["command"] == ["ok", "./private-fixture.json", "--json-output"]
assert "git_branch" not in summary["environment"]
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
PY

echo "test-peekaboo-perf: ok"
