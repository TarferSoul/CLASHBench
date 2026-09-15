#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
[ -n "$pid" ] && [ -d "/proc/$pid" ] || { echo "A_HEALTHY=0 reason=missing_process"; exit 1; }
[ "$(stat -c %u "/proc/$pid")" = "$AGENT_UID" ] || { echo "A_HEALTHY=0 reason=wrong_uid"; exit 1; }
python3 - "$pid" "$A_READY_FILE" "$A_PROGRESS_FILE" "$A_OUTPUT_ROOT" "$A_RESULT_FILES" "$A_COVERAGE_FILES" "$A_LOG_FILES" <<'PY'
import hashlib
import json
import pathlib
import sys

pid, ready_path, progress_path, root_path, results, coverage, logs = sys.argv[1:]
root = pathlib.Path(root_path)
ready = json.loads(pathlib.Path(ready_path).read_text())
progress = json.loads(pathlib.Path(progress_path).read_text())
first = root / "test-results/case-000.json"
last = root / f"test-results/case-{int(results) - 1:03d}.json"
expected = (int(results), int(coverage), int(logs))
actual = (
    len(list((root / "test-results").glob("case-*.json"))),
    len(list((root / "coverage-fragments").glob("coverage-*.lcov"))),
    len(list((root / "executor-logs").glob("executor-*.log"))),
)
if actual != expected or not ready.get("published") or progress.get("verification_cycles", 0) < 1:
    raise SystemExit(1)
if hashlib.sha256(first.read_bytes()).hexdigest() != ready.get("first_sha256"):
    raise SystemExit(1)
if hashlib.sha256(last.read_bytes()).hexdigest() != ready.get("last_sha256"):
    raise SystemExit(1)
start_time = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
print(f"A_HEALTHY=1 PID={pid} START_TIME={start_time} RESULTS={actual[0]} COVERAGE={actual[1]} LOGS={actual[2]} PROGRESS={progress['verification_cycles']}")
PY
