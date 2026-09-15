#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
. "$SCHED_ENV"

python3 - "$A_PID_FILE" "$A_STATE_FILE" "$A_PROGRAM" "$A_INPUT" "$A_TRUST_PATH" \
  "$A_NICE" "$B_NICE" "$A_CFS_WEIGHT" "$B_CFS_WEIGHT" "$LANE_CPU" "$A_PROGRESS_FIELD" "$A_DIGEST_FIELD" <<'PY'
import hashlib, json, os, pathlib, sys, time
(pid_file, state_file, program, input_path, trust_path, a_nice, b_nice,
 a_weight, b_weight, cpu, progress_field, digest_field) = sys.argv[1:]
pid = int(pathlib.Path(pid_file).read_text())
state = json.loads(pathlib.Path(state_file).read_text())
fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()

def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

def load_weight(pid_value):
    line = next(item for item in pathlib.Path(f"/proc/{pid_value}/sched").read_text().splitlines() if item.strip().startswith("se.load.weight"))
    return int(line.split(":", 1)[1]) // 1024

trust = {
    "schema": "weighted-priority-a-trust-v1",
    "captured_at": time.time(),
    "boot_id": pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
    "pid": pid,
    "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "start_ticks": int(fields[21]),
    "state": fields[2],
    "nice": int(fields[18]),
    "scheduler_policy": os.sched_getscheduler(pid),
    "cfs_load_weight": load_weight(pid),
    "affinity": sorted(os.sched_getaffinity(pid)),
    "expected_a_nice": int(a_nice),
    "expected_b_nice": int(b_nice),
    "expected_a_weight": int(a_weight),
    "expected_b_weight": int(b_weight),
    "lane_cpu": int(cpu),
    "program_sha256": sha(program),
    "input_sha256": sha(input_path),
    "progress_field": progress_field,
    "progress": int(state[progress_field]),
    "digest_field": digest_field,
    "digest": state[digest_field],
    "cpu_ticks": int(fields[13]) + int(fields[14]),
}
path = pathlib.Path(trust_path)
path.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
os.chmod(path, 0o600)
print(f"TRUST_CAPTURED=1 pid={pid} progress={trust['progress']} nice={trust['nice']} cfs_weight={trust['cfs_load_weight']}")
PY
