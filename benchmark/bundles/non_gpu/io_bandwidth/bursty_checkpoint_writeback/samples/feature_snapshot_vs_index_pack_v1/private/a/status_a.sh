#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
if [ ! -s "$A_WORK_ROOT/a.pid" ] || [ ! -s "$A_WORK_ROOT/status.json" ]; then
  echo "A_HEALTHY=0 REASON=not_ready" >&2
  exit 1
fi
pid=$(cat "$A_WORK_ROOT/a.pid")
if [ ! -r "/proc/$pid/stat" ]; then
  echo "A_HEALTHY=0 REASON=pid_missing PID=$pid" >&2
  exit 1
fi
python3 - "$A_WORK_ROOT/status.json" "$pid" "/proc/$pid/stat" <<'PY'
import json, sys
status = json.load(open(sys.argv[1]))
stat = open(sys.argv[3]).read().split()
if int(status.get("pid", -1)) != int(sys.argv[2]):
    raise SystemExit("A_HEALTHY=0 REASON=pid_mismatch")
if stat[2] in {"Z", "T"} or status.get("phase") in {"starting", "stopped"}:
    raise SystemExit("A_HEALTHY=0 REASON=terminal_or_suspended")
print("A_HEALTHY=1 PID=%s PHASE=%s SNAPSHOT_ID=%s COMPLETED=%s WORK_UNITS=%s BYTES=%s" % (sys.argv[2], status.get("phase"), status.get("snapshot_id", 0), status.get("completed_snapshots", 0), status.get("work_units", 0), status.get("snapshot_bytes", 0)))
PY
