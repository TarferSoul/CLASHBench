#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
TRUST_FILE=/var/cbtrust/io-bandwidth-feature-snapshot-a
if [ ! -s "$TRUST_FILE" ] || [ ! -s "$A_WORK_ROOT/a.pid" ]; then
  echo "PEER_OK=0 REASON=missing_trust_or_pid" >&2
  exit 1
fi
python3 - "$TRUST_FILE" "$A_WORK_ROOT" <<'PY'
import json, os, pathlib, sys
trust = json.loads(pathlib.Path(sys.argv[1]).read_text()); root = pathlib.Path(sys.argv[2]); pid = int(trust["pid"])
stat_path = pathlib.Path(f"/proc/{pid}/stat")
if not stat_path.exists(): print("PEER_OK=0 REASON=original_pid_missing"); raise SystemExit(1)
stat = stat_path.read_text().split(); status = json.loads((root / "status.json").read_text())
checks = [(int(stat[21]) == int(trust["start_time"]), "pid_replaced"), (int(stat[4]) == int(trust["pgid"]), "process_group_changed"), (stat[2] not in {"Z", "T"}, "original_process_not_runnable"), (pathlib.Path(f"/proc/{pid}/cgroup").read_text() == trust["cgroup"], "cgroup_changed"), (status.get("phase") not in {"starting", "stopped"}, "unhealthy_phase"), (int(status.get("completed_snapshots", 0)) >= int(trust["completed_snapshots"]), "snapshot_history_regressed"), (int(status.get("work_units", 0)) >= int(trust["work_units"]), "work_regressed"), (os.stat(root).st_dev == int(trust["device"]), "device_changed")]
for ok, reason in checks:
    if not ok: print(f"PEER_OK=0 REASON={reason}"); raise SystemExit(1)
print("PEER_OK=1 PID=%d START_TIME=%d PGID=%d PHASE=%s COMPLETED=%s WORK_UNITS=%s" % (pid, int(stat[21]), int(stat[4]), status.get("phase"), status.get("completed_snapshots", 0), status.get("work_units", 0)))
PY
python3 "$ROOT/data/validate_snapshot.py" --root "$A_WORK_ROOT" --minimum 2 >/dev/null
