#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"

python3 - "$A_PORT" "$A_PROGRAM" "$A_TRUST_PATH" <<'PY'
import hashlib, json, os, pathlib, sys, urllib.request
port, program, trust_path = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=2) as response:
        metrics = json.loads(response.read())
    def proc(value):
        path = pathlib.Path(f"/proc/{value}")
        fields = (path / "stat").read_text().split()
        return {"pid": value, "uid": path.stat().st_uid, "pgid": int(fields[4]), "state": fields[2], "start_ticks": int(fields[21]), "affinity": sorted(os.sched_getaffinity(value))}
    if pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip() != trust["boot_id"]:
        raise ValueError("BOOT_ID_CHANGED")
    if hashlib.sha256(pathlib.Path(program).read_bytes()).hexdigest() != trust["program_sha256"]:
        raise ValueError("PROGRAM_CHANGED")
    current_cpu_max = pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().strip() if pathlib.Path("/sys/fs/cgroup/cpu.max").exists() else "legacy"
    if current_cpu_max != trust["cpu_max"]:
        raise ValueError("CPU_CONFIGURATION_CHANGED")
    for expected in [trust["supervisor"], *trust["workers"]]:
        current = proc(expected["pid"])
        for key in ("uid", "pgid", "start_ticks", "affinity"):
            if current[key] != expected[key]:
                raise ValueError(f"PROCESS_{key.upper()}_CHANGED")
        if current["state"] in {"T", "Z", "X"}:
            raise ValueError("PROCESS_NOT_RUNNING")
    if metrics.get("worker_pids") != [item["pid"] for item in trust["workers"]]:
        raise ValueError("WORKER_SET_CHANGED")
    if any(now <= before for now, before in zip(metrics["worker_units"], trust["metrics"]["worker_units"])):
        raise ValueError("WORKER_PROGRESS_STOPPED")
    if metrics.get("rolled_events", 0) <= trust["metrics"].get("rolled_events", 0):
        raise ValueError("ROLLUP_PROGRESS_STOPPED")
    print(f"PEER_OK=1 PID={trust['supervisor']['pid']} WORKERS={len(trust['workers'])} BATCHES={metrics['committed_batches']} EVENTS={metrics['rolled_events']}")
except Exception as exc:
    print(f"PEER_OK=0 REASON={str(exc).replace(' ', '_')}")
    raise SystemExit(1)
PY
