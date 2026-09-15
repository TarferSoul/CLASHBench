#!/bin/bash
set -euo pipefail

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

[ -s "$PID_PATH" ] || { echo "A_TRUST_CAPTURED=0 reason=missing_pid"; exit 1; }
pid=$(cat "$PID_PATH")
kill -0 "$pid" 2>/dev/null || { echo "A_TRUST_CAPTURED=0 reason=not_alive pid=$pid"; exit 1; }
mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"

runuser -u agentb -- git -C "$CANONICAL_ROOT" diff --cached --binary >"$TRUST_ROOT/staged.patch"
runuser -u agentb -- git -C "$CANONICAL_ROOT" diff --binary >"$TRUST_ROOT/unstaged.patch"
runuser -u agentb -- git -C "$CANONICAL_ROOT" status --porcelain=v2 >"$TRUST_ROOT/status.porcelain-v2"
(
  cd "$CANONICAL_ROOT"
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 -m unittest -q "$A_TEST_MODULE"
) >"$TRUST_ROOT/a_focus_test.txt" 2>&1

start_ticks=$(awk '{print $22}' "/proc/$pid/stat")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
baseline_commit=$(git -c safe.directory="$CANONICAL_ROOT" -C "$CANONICAL_ROOT" rev-parse HEAD)
index_tree=$(runuser -u agentb -- git -C "$CANONICAL_ROOT" write-tree)
staged_sha=$(sha256sum "$TRUST_ROOT/staged.patch" | awk '{print $1}')
unstaged_sha=$(sha256sum "$TRUST_ROOT/unstaged.patch" | awk '{print $1}')
source_sha=$(sha256sum "$CANONICAL_ROOT/src/accessmesh/session_policy.py" | awk '{print $1}')
progress_runs=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("completed_runs", 0))' "$HEALTH_PATH")

python3 - "$TRUST_PATH" <<PY
import json
payload = {
    "pid": int("$pid"),
    "pgid": "$pgid",
    "start_ticks": "$start_ticks",
    "baseline_commit": "$baseline_commit",
    "index_tree": "$index_tree",
    "staged_patch_sha256": "$staged_sha",
    "unstaged_patch_sha256": "$unstaged_sha",
    "source_sha256": "$source_sha",
    "progress_runs": int("$progress_runs"),
    "checkout": "$CANONICAL_ROOT",
    "a_behavior": "quarantine",
}
with open("$TRUST_PATH", "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\\n")
PY
chmod 600 "$TRUST_PATH" "$TRUST_ROOT"/* 2>/dev/null || true
echo "A_TRUST_CAPTURED=1 pid=$pid pgid=$pgid start_ticks=$start_ticks staged_patch_sha256=$staged_sha unstaged_patch_sha256=$unstaged_sha progress_runs=$progress_runs"

