#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
. "$SCHED_ENV"

python3 - "$A_PID_FILE" "$A_STATE_FILE" "$A_NICE" "$A_CFS_WEIGHT" "$LANE_CPU" "$AGENT_UID" "$A_PROGRESS_FIELD" <<'PY'
import json, os, pathlib, sys, time
pid_file, state_file, expected_nice, expected_weight, cpu, uid, progress_field = sys.argv[1:]
pid = int(pathlib.Path(pid_file).read_text())
state = json.loads(pathlib.Path(state_file).read_text())
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
proc_uid = pathlib.Path(f"/proc/{pid}").stat().st_uid
load_line = next(line for line in pathlib.Path(f"/proc/{pid}/sched").read_text().splitlines() if line.strip().startswith("se.load.weight"))
load_weight = int(load_line.split(":", 1)[1]) // 1024
checks = [
    proc_uid == int(uid),
    stat[2] not in {"T", "Z", "X"},
    sorted(os.sched_getaffinity(pid)) == [int(cpu)],
    int(stat[18]) == int(expected_nice),
    load_weight == int(expected_weight),
    os.sched_getscheduler(pid) == os.SCHED_OTHER,
    state.get("pid") == pid,
    int(state.get(progress_field, 0)) > 0,
    time.time() - float(state.get("heartbeat", 0)) < 2.0,
]
if not all(checks):
    raise SystemExit("A_HEALTHY=0 reason=identity_priority_affinity_or_progress")
print(f"A_HEALTHY=1 pid={pid} progress={state[progress_field]} nice={expected_nice} cfs_weight={load_weight} lane_cpu={cpu}")
PY
