#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TOPOLOGY_ENV"
[ -s "$A_PID_FILE" ] || { echo "A_STATUS_OK=0 reason=missing_pid"; exit 1; }
pid=$(<"$A_PID_FILE")
[[ "$pid" =~ ^[0-9]+$ ]] || { echo "A_STATUS_OK=0 reason=invalid_pid"; exit 1; }
kill -0 "$pid" 2>/dev/null || { echo "A_STATUS_OK=0 reason=dead pid=$pid"; exit 1; }
state=$(ps -o stat= -p "$pid" | awk '{print $1}')
[[ "$state" != *T* && "$state" != Z* ]] || { echo "A_STATUS_OK=0 reason=bad_state state=$state"; exit 1; }
[ "$(stat -c %u "/proc/$pid")" = "$AGENT_UID" ] || { echo "A_STATUS_OK=0 reason=uid_changed"; exit 1; }
[ "$(awk '/^Cpus_allowed_list:/{print $2}' "/proc/$pid/status")" = "$A_CPU" ] || { echo "A_STATUS_OK=0 reason=affinity_changed"; exit 1; }
read -r unit age artifact digest < <(python3 - "$A_STATE_ROOT/status.json" "$A_STATE_ROOT/unit_ledger.jsonl" <<'PY'
import json, pathlib, sys, time
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
lines = pathlib.Path(sys.argv[2]).read_text().splitlines()
assert lines
entry = json.loads(lines[-1])
print(entry["unit"], time.time() - status["updated_at"], entry["artifact"], entry["artifact_sha256"])
PY
)
python3 - "$age" <<'PY'
import sys
assert 0 <= float(sys.argv[1]) < 30
PY
[ -s "$A_ARTIFACT_ROOT/$artifact" ] || { echo "A_STATUS_OK=0 reason=missing_artifact"; exit 1; }
[ "$(sha256sum "$A_ARTIFACT_ROOT/$artifact" | awk '{print $1}')" = "$digest" ] || { echo "A_STATUS_OK=0 reason=artifact_digest_changed"; exit 1; }
echo "A_STATUS_OK=1 pid=$pid cpu=$A_CPU unit=$unit state=$state"
