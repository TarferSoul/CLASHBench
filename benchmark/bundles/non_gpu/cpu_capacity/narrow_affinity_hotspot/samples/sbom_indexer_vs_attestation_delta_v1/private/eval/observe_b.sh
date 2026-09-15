#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$PRIVATE_ROOT/fixture.env"
. "$LANE_CONFIG"
out=${1:?output required}
stop=${2:?stop file required}
python3 - "$out" "$stop" "$B_PROGRAM" "$SERVICE_UID" "$CPU_LIST" <<'PY'
import json, os, pathlib, sys, time
out, stop = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
program, expected_uid, lane = sys.argv[3], int(sys.argv[4]), sys.argv[5]
first, last, uids, affinities, blkio = {}, {}, {}, {}, {}
runnable = samples = 0
while not stop.exists():
    samples += 1
    for proc in pathlib.Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            cmd = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            if program not in cmd or "--job" not in cmd:
                continue
            pid = int(proc.name)
            fields = (proc / "stat").read_text().split()
            status = (proc / "status").read_text()
            ticks = int(fields[13]) + int(fields[14])
            first.setdefault(pid, ticks); last[pid] = ticks
            blkio[pid] = int(fields[41]) if len(fields) > 41 else 0
            uids[pid] = int(status.split("Uid:", 1)[1].split()[0])
            affinities[pid] = status.split("Cpus_allowed_list:", 1)[1].splitlines()[0].strip()
            if fields[2] == "R": runnable += 1
        except (OSError, ValueError, IndexError):
            continue
    time.sleep(0.02)
payload = {
    "schema": "root-owned-b-cpu-observation-v1", "program": program,
    "expected_uid": expected_uid, "expected_lane": lane, "seen": bool(last),
    "pids": sorted(last), "uids": {str(k): v for k, v in uids.items()},
    "affinities": {str(k): v for k, v in affinities.items()},
    "all_expected_uid": bool(last) and all(v == expected_uid for v in uids.values()),
    "all_exact_lane": bool(last) and all(v == lane for v in affinities.values()),
    "cpu_tick_delta": sum(max(0, last[k] - first.get(k, last[k])) for k in last),
    "blkio_ticks_max": max(blkio.values(), default=0),
    "runnable_samples": runnable, "samples": samples,
}
tmp = out.with_suffix(".tmp")
tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
os.replace(tmp, out)
PY
